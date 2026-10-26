#!/usr/bin/env python3
"""Logic tests for Wingman. Each function mirrors the Objective-C code 1:1.

  1. settings merge  (WMSettings reload / setValue)   - "my choice keeps resetting"
  2. reply parsing   (WMAPIClient _parseReplies / _humanize)
  3. DeepSeek URLs   (WMSettings deepseekBaseURL)
  4. OCR ignore rules + banner block (WMOCR)
"""
import re, json, sys, os

FAIL = 0
def check(name, got, want):
    global FAIL
    ok = got == want
    FAIL += (not ok)
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + ("" if ok else f"\n        got  {got!r}\n        want {want!r}"))

# ───────────────────────── 1. settings ─────────────────────────
class Device:
    """global_store = what Settings / cfprefs holds.
    can_read / can_write = what the app sandbox allows for the global store."""
    def __init__(self, can_read, can_write, global_store=None):
        self.can_read, self.can_write = can_read, can_write
        self.global_store = dict(global_store or {})
        self.local = {}          # this app's own NSUserDefaults

    def read_global(self):
        return dict(self.global_store) if self.can_read else {}

    def reload(self):
        g = self.read_global()
        merged = dict(g)
        for k, entry in self.local.items():
            if isinstance(entry, dict) and "v" in entry:
                v, seen = entry["v"], entry.get("g")
            else:
                v, seen = entry, g.get(k)
            now = g.get(k)
            if (now is None and seen is None) or now == seen or now is None:
                merged[k] = v
        self.prefs, self.glob = merged, g

    def set_value(self, k, v):
        wrote = False
        if self.can_write:
            self.global_store[k] = v; wrote = True
        self.reload()
        back = self.glob.get(k)
        landed = wrote and back == v
        self.local[k] = {"v": v, "g": back} if back is not None else {"v": v}
        self.reload()
        return landed

    def settings_app_sets(self, k, v):      # you edit it in the Settings app
        self.global_store[k] = v

    def provider(self):
        self.reload()
        return "DeepSeek" if self.prefs.get("apiProvider", 0) == 1 else "Claude"

print("1. Remembering Claude vs DeepSeek")
for label, r, w in [("sandbox blocks read+write", False, False),
                    ("read allowed, write blocked", True, False),
                    ("read+write allowed", True, True)]:
    d = Device(r, w, {"apiProvider": 0})          # Settings says Claude
    d.set_value("apiProvider", 1)                 # you pick DeepSeek in Wingman
    check(f"[{label}] pick DeepSeek, reopen -> DeepSeek", d.provider(), "DeepSeek")
    d.set_value("apiProvider", 0)                 # pick Claude again
    check(f"[{label}] pick Claude, reopen -> Claude", d.provider(), "Claude")
    d.set_value("apiProvider", 1)
    for _ in range(3): d.reload()                 # app relaunches, sheet reopens
    check(f"[{label}] survives repeated reopen", d.provider(), "DeepSeek")

print("\n   Settings edits made AFTER a Wingman choice should win")
d = Device(True, False, {"apiProvider": 0})
d.set_value("apiProvider", 1)                     # Wingman: DeepSeek (app-only)
d.settings_app_sets("apiProvider", 0)             # unchanged value -> still DeepSeek
check("Settings re-saving the same old value doesn't steal it", d.provider(), "DeepSeek")
d = Device(True, False, {"claudeModel": "old-model"})
d.set_value("claudeModel", "picked-in-wingman")
d.reload(); check("model picked in Wingman wins", d.prefs["claudeModel"], "picked-in-wingman")
d.settings_app_sets("claudeModel", "typed-in-settings")
d.reload(); check("later Settings edit wins over it", d.prefs["claudeModel"], "typed-in-settings")

print("\n   Keys")
d = Device(False, False, {})
d.set_value("claudeAPIKey", "sk-ant-xyz")
d.reload(); check("key saved in Wingman is found when sandbox blocks Settings", d.prefs.get("claudeAPIKey"), "sk-ant-xyz")
d = Device(True, True, {})
check("set_value reports 'saved for all apps' when write lands", d.set_value("deepseekAPIKey", "sk-1"), True)
d = Device(True, False, {})
check("set_value reports 'this app only' when write blocked", d.set_value("deepseekAPIKey", "sk-1"), False)

print("\n   Legacy local format (1.5.0 stored plain values)")
d = Device(False, False, {}); d.local["claudeAPIKey"] = "sk-old"
d.reload(); check("old plain value still read", d.prefs.get("claudeAPIKey"), "sk-old")

# ───────────────────────── 2. reply parsing ─────────────────────────
def humanize(s):
    t = s.strip()
    t = t.replace(" — ", ", ").replace("—", ", ").replace(" – ", ", ").replace("–", "-")
    if len(t) >= 2 and t.startswith('"') and t.endswith('"'): t = t[1:-1]
    return t

def parse_replies(raw, n=3):
    if not raw: return []
    out, obj = [], None
    a, b = raw.find("{"), raw.rfind("}")
    if a != -1 and b > a:
        try:
            obj = json.loads(raw[a:b+1])
            if isinstance(obj, dict): obj = obj.get("replies")
        except Exception: obj = None
    if not isinstance(obj, list):
        a, b = raw.find("["), raw.rfind("]")
        if a != -1 and b > a:
            try: obj = json.loads(raw[a:b+1])
            except Exception: obj = None
    if isinstance(obj, list):
        out = [r for r in obj if isinstance(r, str)]
    else:
        for line in raw.splitlines():
            t = line.strip("0123456789.)-*\"' \t")
            if len(t) > 1: out.append(t)
    clean = []
    for r in out:
        t = humanize(r)
        if t: clean.append(t)
        if len(clean) == n: break
    return clean

print("\n2. Reading the AI's 3 replies")
check("plain JSON", parse_replies('{"replies":["a b","c d","e f"]}'), ["a b","c d","e f"])
check("JSON in a ```json fence", parse_replies('```json\n{"replies": ["x", "y", "z"]}\n```'), ["x","y","z"])
check("text before JSON (web search)", parse_replies('I searched.\n{"replies":["one","two","three"]}'), ["one","two","three"])
check("em dash removed", parse_replies('{"replies":["yeah — sure","b","c"]}')[0], "yeah, sure")
check("bare array", parse_replies('["p","q","r"]'), ["p","q","r"])
check("numbered list fallback", parse_replies('1. Hey there\n2. Sure thing\n3. Lol ok'), ["Hey there","Sure thing","Lol ok"])
check("more than 3 -> first 3", parse_replies('{"replies":["1a","2b","3c","4d"]}'), ["1a","2b","3c"])
check("Hinglish + emoji kept", parse_replies('{"replies":["Arre yaar 😂 chill kar"]}'), ["Arre yaar 😂 chill kar"])
check("empty -> none", parse_replies(""), [])

# ───────────────────────── 3. DeepSeek URLs ─────────────────────────
def ds_base(b):
    b = (b or "").strip() or "https://api.deepseek.com"
    if not b.startswith(("http://", "https://")): b = "https://" + b
    b = b.rstrip("/")
    if b.endswith("/chat/completions"): b = b[:-len("/chat/completions")]
    return b.rstrip("/")

print("\n3. DeepSeek address handling")
for typed, want in [("https://api.deepseek.com", "https://api.deepseek.com"),
                    ("api.deepseek.com", "https://api.deepseek.com"),
                    ("https://api.deepseek.com/", "https://api.deepseek.com"),
                    ("https://api.deepseek.com/chat/completions", "https://api.deepseek.com"),
                    ("https://api.deepseek.com/v1", "https://api.deepseek.com/v1"),
                    ("", "https://api.deepseek.com")]:
    check(f"{typed!r:44} -> {want}", ds_base(typed), want)

# ───────────────────────── 4. OCR rules ─────────────────────────
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "WMOCR.m")).read()
blk = src[src.index("phrases = @["):src.index("];", src.index("phrases = @["))]
phrases = re.findall(r'@"([^"]+)"', blk)
mon = "(jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|aug|august|sep|sept|september|oct|october|nov|november|dec|december)"
date = re.compile(rf"^(today|yesterday|monday|tuesday|wednesday|thursday|friday|saturday|sunday|(mon|tue|wed|thu|fri|sat|sun)[a-z]*,? \d{{1,2}} {mon}( \d{{4}})?|\d{{1,2}} {mon}( \d{{4}})?|{mon} \d{{1,2}},?( \d{{4}})?|\d{{1,2}}/\d{{1,2}}/\d{{2,4}}|\d{{1,2}}:\d{{2}}( ?(am|pm))?)$")
def notice(l):
    l = l.lower().strip()
    return (not l) or any(p in l for p in phrases) or bool(date.match(l))

print("\n4. Chat reading: notices dropped, messages kept")
for t, want in [("🔒 Messages and calls are now end-to-end", True),
                ("encrypted. Only people in this chat can read, listen", True),
                ("to, or share them. Learn more.", True),
                ("Messages and calls are end-to-end encrypted. No one outside of this chat", True),
                ("Waiting for this message. This may take a while.", True),
                ("This message was deleted", True), ("Today", True), ("Sat, 17 Oct", True),
                ("1.32 I got deposited in my account from zerodha", False),
                ("That's why action is necessary against him", False),
                ("5 marks", False), ("may be later", False), ("10 minutes", False), ("Lmk", False)]:
    check(f"{'drop' if want else 'keep'}: {t[:52]}", notice(t), want)

print("\n" + ("ALL PASSED" if FAIL == 0 else f"{FAIL} FAILED"))
sys.exit(1 if FAIL else 0)
