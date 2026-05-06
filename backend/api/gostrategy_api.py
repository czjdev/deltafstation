"""
GoStrategy API - 专注策略运行：

- 路由
  - PUT  /api/gostrategy/<account_id>/strategy  启动或替换账户策略。
  - GET  /api/gostrategy/<account_id>/chart     获取当前策略的 K 线与信号。

- 账户与配置
  - account_id：账户标识（当前为 SIM_xxx，后续可扩展 BROKER_xxx）。
  - _resolve_account_config_path(account_id)：解析到账户配置文件（data/simulations/<id>.json）。
  - 本 API 只负责「选策略 + 启动」和「chart」，账户创建等由 simulation_api 处理。

- set_strategy
  - 校验账户存在，body 含 strategy_id / symbol。
  - stop_same_account(account_id)：停掉同账户上的 StrategyEngine / SimulationEngine，并把最新 engine_state 落盘。
  - 读取配置中的 engine_state 作为恢复快照，调用 StrategyEngine.start(..., state=engine_state) 启动策略。
  - 更新配置中的 status/strategy_id/symbol/signal_interval 并落盘，再合并最新 state 返回给前端。

- chart
  - 要求账户上有正在运行的策略（StrategyEngine.get_run_info 非空）。
  - 直接返回 StrategyEngine.get_chart_data(account_id) 的 K 线与信号；未运行或异常时返回 400/500。
"""
from flask import Blueprint, request, jsonify
import os
import json

from backend.core.strategy_engine import StrategyEngine
from backend.core.utils.sim_persistence import config_path, stop_same_account
from backend.core.utils.engine_snapshot import inject_strategy_id

gostrategy_bp = Blueprint('gostrategy', __name__)


def _resolve_account_config_path(account_id: str):
    """解析 account_id 对应的配置路径。当前仅支持 simulation，后续 broker_api 实现后扩展。"""
    path = config_path(account_id)
    if os.path.exists(path):
        return path
    # 后续：if account_id.startswith('BROKER_'): return broker_config_path(account_id)
    return None


@gostrategy_bp.route('/<account_id>/strategy', methods=['PUT'])
def set_strategy(account_id):
    """设置账户的策略（启动/替换）。body: strategy_id, symbol, signal_interval?, lookback_bars?"""
    try:
        cfg_path = _resolve_account_config_path(account_id)
        if not cfg_path:
            return jsonify({'error': 'Account not found'}), 404
        data = request.get_json() or {}
        strategy_id = (data.get('strategy_id') or '').strip()
        symbol = (data.get('symbol') or '').strip().upper()
        if not strategy_id or not symbol:
            return jsonify({'error': 'Missing strategy_id or symbol'}), 400
        # 先停掉同账户上的其它实例，并将其最新 engine_state 落盘
        stop_same_account(account_id)
        # 再读取最新的账户配置（包含刚刚写入的 engine_state）
        with open(cfg_path, 'r', encoding='utf-8') as f:
            cfg = json.load(f)
        engine_state = cfg.get('engine_state')
        order_amount = None
        if 'order_amount' in data and data['order_amount'] is not None:
            try:
                v = float(data['order_amount'])
                if v > 0:
                    order_amount = v
            except (TypeError, ValueError):
                pass
        signal_interval = (data.get('signal_interval') or '1d').lower()
        lookback_bars = int(data.get('lookback_bars') or 50)
        data_source = (data.get('data_source') or 'miniqmt').lower()
        try:
            StrategyEngine.start(
                account_id=account_id,
                strategy_id=strategy_id,
                symbol=symbol,
                initial_capital=float(cfg.get('initial_capital', 100000)),
                commission=float(cfg.get('commission', 0.001)),
                signal_interval=signal_interval,
                lookback_bars=lookback_bars,
                interval=10.0,
                order_amount=order_amount,
                state=engine_state,
                data_source=data_source,
            )
        except Exception as e:
            return jsonify({'error': str(e)}), 500
        cfg['status'] = 'running'
        cfg['strategy_id'] = strategy_id
        cfg['symbol'] = symbol
        cfg['signal_interval'] = signal_interval
        with open(cfg_path, 'w', encoding='utf-8') as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
        state = StrategyEngine.get_state(account_id)
        if state:
            inject_strategy_id(state, strategy_id)
            cfg.update(state)
        return jsonify({'simulation': cfg})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@gostrategy_bp.route('/<account_id>/chart', methods=['GET'])
def chart(account_id):
    """K线+信号（策略运行中）。直接使用 deltafq LiveEngine.get_chart_data。"""
    cfg_path = _resolve_account_config_path(account_id)
    if not cfg_path:
        return jsonify({'error': 'Account not found'}), 404
    info = StrategyEngine.get_run_info(account_id)
    if not info:
        return jsonify({'error': 'Strategy not running'}), 400
    try:
        chart_data = StrategyEngine.get_chart_data(account_id)
        if chart_data is None:
            return jsonify({'candles': [], 'signals': []})
        return jsonify(chart_data)
    except Exception as e:
        return jsonify({'error': str(e)}), 500
