#!/usr/bin/env python3
"""<项目名> 验收器（模板）——把下面每条换成 SPEC/README 的真实判据。

纪律：
  * 判据独立于被测代码（自己复算，不调被测方的测试）
  * 先跑基线（现状一定 FAIL），改完再跑（应全 PASS）——否则你没法证明"改好了"
用法: python harness/verify_criteria.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# harness_kit 由 wfctl harness 通过 PYTHONPATH 提供（技能 scripts/ 目录）；手动跑:
#   PYTHONPATH="<技能>/scripts" python harness/verify_criteria.py
from harness_kit import Checker, approx, parse_table, raises, repo_root, run_cli  # noqa: E402

REPO = repo_root()
sys.path.insert(0, REPO)

c = Checker("<项目名> 验收")

# ---- 例 1：直接调函数判行为 -------------------------------------------------
# from pkg.pricing import base_fee          # noqa: E402
# c.check("CR1 基础费率 spot=0.0010",
#         lambda: (approx(base_fee(1000, "spot"), 1.0, 1e-9), f"got={base_fee(1000,'spot')}"))

# ---- 例 2：异常路径 --------------------------------------------------------
# c.check("CR7 非法输入必须抛",
#         lambda: (raises(lambda: validate(-1.0), "ValueError"), "qty=-1"))

# ---- 例 3：CLI 输出与独立复算对拍（最有用的一类）---------------------------
# rc, out, err = run_cli(["-m", "pkg.cli", "--from", "2026-09-01", "--to", "2026-09-30"], cwd=REPO)
# rows, total = parse_table(out)
# c.check("CR10 CLI TOTAL 与独立复算一致",
#         lambda: (rc == 0 and approx(total, 12345.67), f"rc={rc} total={total}"))

c.check("示例判据（请替换）", lambda: (False, "模板未填写判据"))

c.finish()
