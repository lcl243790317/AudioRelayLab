"""仅汇总导出日志中的证据；不推断微信收录或真实扬声器发声。"""
import argparse
import json
from collections import Counter
from pathlib import Path
import sys

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")


def groups(path):
    text = path.read_text(encoding="utf-8-sig")
    if path.suffix.lower() == ".json":
        value = json.loads(text)
        items = value if isinstance(value, list) else [value]
        return [(str(item.get("id", "实验")), item.get("logs", [])) for item in items]
    if path.suffix.lower() == ".jsonl":
        return [(path.name, [json.loads(line) for line in text.splitlines() if line.strip()])]
    entries = []
    # Snapshot 可以跨行，只按具有标准前缀的行拆分事件，其余行属于先前事件。
    for line in text.splitlines():
        fields = line.split(" | ", 4)
        if len(fields) == 5 and fields[1].startswith("+") and fields[2].startswith("uptime="):
            entries.append({"localTime": fields[0], "category": fields[3], "message": fields[4]})
        elif entries:
            entries[-1]["message"] += "\n" + line
    return [(path.name, entries)]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    for identifier, entries in groups(args.log):
        print(f"\n记录组：{identifier}；事件数：{len(entries)}")
        for category, count in Counter(item.get("category", "未知") for item in entries).items():
            print(f"  {category}：{count}")
        print("关键原始事件：")
        for item in entries:
            if any(word in item.get("category", "") for word in ["调度", "中断", "恢复", "可观察播放", "播放完成", "路由变化", "用户实验结果", "主动停止"]):
                print(f"  {item.get('localTime', item.get('date', ''))} | {item.get('category')} | {item.get('message')}")
    print("\n这些事件不能直接确认实际扬声器起始时间；微信收录结果以用户真机回听为准。")
