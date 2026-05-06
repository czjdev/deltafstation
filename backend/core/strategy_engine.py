"""
策略引擎核心类（基于 deltafq LiveEngine）

StrategyEngine 类方法说明：
  start            启动指定账户的策略引擎，可选从 state 恢复资金/持仓/订单等。
  stop             停止指定账户的策略引擎，并返回当前资金/持仓/订单快照。
  is_running       判断指定 account_id 上是否有策略在运行。
  get_running_ids  返回当前所有正在运行策略的 account_id 列表。
  get_state        获取当前策略运行中的底层引擎快照（不停止）。
  get_run_info     获取策略 id、标的、信号周期及最近一次信号信息。
  get_run_metrics  获取当前运行策略的绩效指标（与 BacktestEngine API 对齐）。
  get_chart_data   获取当前运行策略的 K 线和信号图表数据。
"""
from typing import List, Optional, Any, Dict
import math
import threading

from deltafq.live import LiveEngine

try:
    import numpy as np
except ImportError:
    np = None

from backend.core.utils.strategy_loader import load_strategy_class
from backend.core.utils.engine_snapshot import build_state_from_engine, restore_engine_from_state


def _get_engine(run: Optional[dict]):
    """从 run 中提取底层 paper ExecutionEngine，失败返回 None。"""
    if not run:
        return None
    gw = getattr(run.get("engine"), "_trade_gw", None)
    return getattr(gw, "_engine", None) if gw else None


def _to_json_serializable(obj: Any) -> Any:
    """将 metrics 中常见的 numpy/pandas 等对象递归转换为 JSON 可序列化形式。"""
    if obj is None:
        return None
    if isinstance(obj, dict):
        return {k: _to_json_serializable(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_to_json_serializable(x) for x in obj]
    if np is not None and hasattr(obj, "item"):  # numpy scalar
        try:
            x = obj.item()
            if isinstance(x, (int, float)) and (math.isnan(x) or math.isinf(x)):
                return None
            if isinstance(x, bool):
                return x
            if isinstance(x, int):
                return int(x)
            if isinstance(x, float):
                return float(x)
            return x
        except (ValueError, AttributeError, TypeError):
            pass
    if hasattr(obj, "strftime"):  # datetime-like
        return str(obj)
    if isinstance(obj, (int, float, str, bool)):
        if isinstance(obj, float) and (math.isnan(obj) or math.isinf(obj)):
            return None
        return obj
    return obj


class StrategyEngine:
    """基于 deltafq LiveEngine 的策略运行管理器。"""
    _runs: dict = {}

    @classmethod
    def start(cls, account_id: str, strategy_id: str, symbol: str, initial_capital: float,
              commission: float = 0.001, signal_interval: str = "1d", lookback_bars: int = 100,
              interval: float = 10.0, order_amount: Optional[float] = None,
              state: Optional[dict] = None, data_source: str = "miniqmt") -> None:
        """启动指定账户的策略引擎，可选从 state 恢复资金/持仓/订单等。

        data_source: 'miniqmt' (默认) 或 'yfinance'. 国内云上 yfinance 通常拉不通.
        """
        if account_id in cls._runs:
            cls.stop(account_id)
        strat = load_strategy_class(strategy_id)(name=strategy_id)
        if order_amount is not None:
            strat.order_amount = order_amount
        engine = LiveEngine(symbol=symbol, interval=interval, lookback_bars=lookback_bars, signal_interval=signal_interval)
        if data_source == "miniqmt":
            engine.set_data_gateway("miniqmt", interval=5.0, mode="poll")
        else:
            engine.set_data_gateway(data_source, interval=interval)
        engine.set_trade_gateway("paper", initial_capital=initial_capital, commission=commission)
        # deltafq 在 _ensure_gateways() 时才创建 _trade_gw/_engine，必须先调用再恢复，否则订单历史进不了引擎
        if getattr(engine, "_ensure_gateways", None):
            engine._ensure_gateways()
        if state:
            eng = _get_engine({"engine": engine})
            if eng:
                restore_engine_from_state(eng, state)
        engine.add_strategy(strat)
        t = threading.Thread(target=lambda: engine.run_live(), daemon=True)
        t.start()
        cls._runs[account_id] = {"engine": engine, "strategy_id": strategy_id, "symbol": symbol,
                                "signal_interval": signal_interval, "thread": t}

    @classmethod
    def stop(cls, account_id: str) -> Optional[dict]:
        """停止指定账户的策略引擎，并返回当前资金/持仓/订单快照（可能为 None）。"""
        run = cls._runs.pop(account_id, None)
        if not run:
            return None
        eng = _get_engine(run)
        try:
            state = build_state_from_engine(eng) if eng else None
        except Exception:
            state = None
        try:
            run["engine"].stop()
        except Exception:
            pass
        return state

    @classmethod
    def is_running(cls, account_id: str) -> bool:
        """判断指定 account_id 上是否有策略在运行。"""
        return account_id in cls._runs

    @classmethod
    def get_state(cls, account_id: str) -> Optional[dict]:
        """获取当前策略运行中的底层引擎快照（不停止）。"""
        run = cls._runs.get(account_id)
        eng = _get_engine(run) if run else None
        if not eng:
            return None
        try:
            return build_state_from_engine(eng)
        except Exception:
            return None

    @classmethod
    def get_run_info(cls, account_id: str) -> Optional[dict]:
        """获取策略 id、标的、信号周期及最近一次信号信息。"""
        run = cls._runs.get(account_id)
        if not run:
            return None
        info = {"strategy_id": run["strategy_id"], "symbol": run["symbol"],
                "signal_interval": run.get("signal_interval", "1d")}
        eng = run["engine"]
        if hasattr(eng, "_last_signal"):
            sig = eng._last_signal
            info["last_signal"] = sig
            info["last_signal_label"] = "买入" if sig == 1 else ("卖出" if sig == -1 else "观望")
        return info

    @classmethod
    def get_run_metrics(cls, account_id: str) -> Optional[Dict[str, Any]]:
        """获取当前运行策略的绩效指标（与 BacktestEngine API 对齐），无数据或异常时返回 None。"""
        run = cls._runs.get(account_id)
        if not run:
            return None
        engine = run["engine"]
        if not hasattr(engine, "calculate_metrics"):
            return None
        try:
            result = engine.calculate_metrics()
            if result is None:
                return None
            # 与 BacktestEngine 一致：calculate_metrics() 返回 (values_metrics_df, metrics_dict)
            if isinstance(result, (list, tuple)) and len(result) >= 2:
                metrics = result[1]
            elif isinstance(result, dict):
                metrics = result
            else:
                return None
            if not isinstance(metrics, dict):
                return None
            return _to_json_serializable(metrics)
        except Exception:
            return None

    @classmethod
    def get_chart_data(cls, account_id: str) -> Optional[dict]:
        """获取当前运行策略的 K 线和信号图表数据。"""
        run = cls._runs.get(account_id)
        if not run:
            return None
        engine = run["engine"]
        if not hasattr(engine, "get_chart_data"):
            return None
        try:
            return engine.get_chart_data()
        except Exception:
            return None

    @classmethod
    def get_running_ids(cls) -> List[str]:
        """返回当前所有正在运行策略的 account_id 列表。"""
        return list(cls._runs.keys())
