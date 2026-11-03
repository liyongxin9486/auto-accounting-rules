#!/system/bin/sh
# 自动记账规则离线合并安装器。只调用本机规则/公共脚本接口，不调用账单分析接口。
set -u
umask 077
MODE="${1:-install}"
case "$MODE" in install|--check|--update) ;; *) echo '用法：sh 本脚本 [--check|--update]'; exit 2;; esac
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd) || exit 1
SCRIPT_PATH="$SCRIPT_DIR/$(basename "$0")"
if [ "$(id -u)" != 0 ]; then
  echo '正在请求 Root 授权，请允许本次脚本运行。'
  # 本文件部署在内部存储根目录；禁止将 shell 特殊字符作为脚本路径的一部分。
  case "$SCRIPT_PATH" in *\'*|*\"*|*\$*|*\`*) echo '请使用不含引号或特殊字符的脚本路径。'; exit 1;; esac
  exec su -c "/system/bin/sh \"$SCRIPT_PATH\" $MODE"
fi
PACKAGE="$SCRIPT_DIR/自动记账完整规则包.zip"
EXPECTED_SHA256="acdcafe91f2beb02e561828846d853c4ee47419412f25e3c8f7788b97e40080e"
PORT="${AUTO_RULE_API_PORT:-52045}"
case "$PORT" in ''|*[!0-9]*) echo '本地服务端口无效。'; exit 1;; esac
BASE="http://127.0.0.1:$PORT"
BACKUP_ROOT="${AUTO_RULE_BACKUP_DIR:-/sdcard/自动记账规则备份}"
for cmd in curl sqlite3 unzip sha256sum mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "缺少命令：$cmd"; exit 1; }
done
[ -r "$PACKAGE" ] || { echo "找不到规则包：$PACKAGE"; exit 1; }
ACTUAL_SHA256=$(sha256sum "$PACKAGE" | cut -d ' ' -f1)
[ "$ACTUAL_SHA256" = "$EXPECTED_SHA256" ] || { echo '规则包校验失败，请重新复制配套 ZIP 和脚本。'; exit 1; }
WORK=$(mktemp -d /data/local/tmp/auto-rules.XXXXXX) || exit 1
STATE="$WORK/state.db"
BACKUP=''
cleanup() {
  # WORK 只由 mktemp 生成，并限定在专用临时目录前缀内。
  case "$WORK" in /data/local/tmp/auto-rules.??????) rm -rf "$WORK";; esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM
die() {
  echo "失败：$*"
  [ -z "$BACKUP" ] || echo "备份和已完成操作记录：$BACKUP"
  echo '未重跑历史账单。中断后可重新运行，已添加的规则会被识别并跳过。'
  exit 1
}
sql() { sqlite3 -bail "$STATE" "$1"; }
api() {
  route="$1"; body="${2:-}"
  if [ -n "$body" ]; then
    curl -fsS --connect-timeout 3 --max-time 30 -H 'Content-Type: application/json; charset=utf-8' \
      --data-binary "@$body" "$BASE$route" > "$WORK/response.json" || return 1
  else
    curl -fsS --connect-timeout 3 --max-time 30 "$BASE$route" > "$WORK/response.json" || return 1
  fi
  code=$(sql "SELECT CASE WHEN json_valid(CAST(readfile('$WORK/response.json') AS TEXT)) THEN json_extract(CAST(readfile('$WORK/response.json') AS TEXT),'$.code') ELSE -1 END;") || return 1
  [ "$code" = 200 ]
}
for file in rules.json common.js category.js manifest.json; do
  unzip -p "$PACKAGE" "$file" > "$WORK/$file" || die "无法读取包内 $file"
done
sql "SELECT CASE WHEN json_valid(CAST(readfile('$WORK/rules.json') AS TEXT)) THEN 1 ELSE 0 END;" | grep -qx 1 || die '规则 JSON 无效'
SCHEMA=$(sql "SELECT json_extract(CAST(readfile('$WORK/manifest.json') AS TEXT),'$.schemaVersion');") || die '无法读取清单'
[ "$SCHEMA" = 1 ] || die '不支持的规则包格式'
sql "CREATE TABLE incoming(seq INTEGER PRIMARY KEY,payload TEXT NOT NULL);
INSERT INTO incoming SELECT CAST(key AS INTEGER),json_set(value,'$.id',0) FROM json_each(CAST(readfile('$WORK/rules.json') AS TEXT));
CREATE TABLE current_rules(payload TEXT NOT NULL);
CREATE TABLE plan(seq INTEGER PRIMARY KEY,action TEXT NOT NULL,existing_id INTEGER DEFAULT 0);" || die '无法建立临时解析库'
COUNT=$(sql 'SELECT count(*) FROM incoming;')
DECLARED=$(sql "SELECT json_extract(CAST(readfile('$WORK/manifest.json') AS TEXT),'$.ruleCount');")
[ "$COUNT" = "$DECLARED" ] && [ "$COUNT" -gt 0 ] || die '规则数量与清单不符'
BAD=$(sql "SELECT count(*) FROM incoming WHERE
 coalesce(json_extract(payload,'$.app'),'')='' OR coalesce(json_extract(payload,'$.name'),'')='' OR
 coalesce(json_extract(payload,'$.type'),'') NOT IN ('DATA','NOTICE','OCR') OR
 coalesce(json_extract(payload,'$.creator'),'') NOT IN ('system','user') OR
 coalesce(json_extract(payload,'$.js'),'')='' OR
 coalesce(json_extract(payload,'$.systemRuleName'),'') NOT GLOB 'rule_[0-9]*' OR
 substr(json_extract(payload,'$.systemRuleName'),6) GLOB '*[^0-9]*' OR
 json_type(payload,'$.enabled') NOT IN ('true','false') OR json_type(payload,'$.autoRecord') NOT IN ('true','false');") || die '规则字段检查失败'
[ "$BAD" = 0 ] || die '规则字段或解析器名称不合法'
DUP=$(sql "SELECT count(*) FROM (SELECT 1 FROM incoming GROUP BY json_extract(payload,'$.app'),json_extract(payload,'$.type'),json_extract(payload,'$.creator'),json_extract(payload,'$.name') HAVING count(*)>1);")
[ "$DUP" = 0 ] || die '规则包内存在重复规则'
echo "规则包校验通过，共 $COUNT 条。正在连接自动记账本地服务……"
if ! api '/rule/list?page=1&limit=10000' 2>/dev/null; then
  echo '尝试打开自动记账，请确认主页显示工作中。'
  am start --user 0 -n net.ankio.auto/.ui.activity.MainActivity >/dev/null 2>&1 || true
  ready=0
  for attempt in 1 2 3 4 5; do
    sleep 1
    if api '/rule/list?page=1&limit=10000' 2>/dev/null; then ready=1; break; fi
  done
  [ "$ready" = 1 ] || die '服务未就绪，请先检查自动记账与 LSPosed 是否正常运行'
fi
cp "$WORK/response.json" "$WORK/before.json" || die '无法保存安装前规则'
sql "INSERT INTO current_rules SELECT value FROM json_each(CAST(readfile('$WORK/before.json') AS TEXT),'$.data');" || die '规则列表格式不兼容'
AMBIGUOUS=$(sql "SELECT count(*) FROM incoming i WHERE (SELECT count(*) FROM current_rules c WHERE
 json_extract(c.payload,'$.app')=json_extract(i.payload,'$.app') AND json_extract(c.payload,'$.type')=json_extract(i.payload,'$.type') AND
 json_extract(c.payload,'$.creator')=json_extract(i.payload,'$.creator') AND json_extract(c.payload,'$.name')=json_extract(i.payload,'$.name'))>1;")
[ "$AMBIGUOUS" = 0 ] || die '目标库存在同一身份的重复规则，请先处理冲突'
sql "INSERT INTO plan SELECT i.seq,CASE WHEN c.payload IS NULL THEN 'add'
 WHEN json_extract(c.payload,'$.js')=json_extract(i.payload,'$.js') AND json_extract(c.payload,'$.systemRuleName')=json_extract(i.payload,'$.systemRuleName') THEN 'skip'
 ELSE 'different' END,coalesce(json_extract(c.payload,'$.id'),0)
 FROM incoming i LEFT JOIN current_rules c ON json_extract(c.payload,'$.app')=json_extract(i.payload,'$.app')
 AND json_extract(c.payload,'$.type')=json_extract(i.payload,'$.type') AND json_extract(c.payload,'$.creator')=json_extract(i.payload,'$.creator')
 AND json_extract(c.payload,'$.name')=json_extract(i.payload,'$.name');" || die '无法生成合并计划'
COLLISIONS=$(sql "SELECT count(*) FROM incoming i JOIN plan p ON i.seq=p.seq JOIN current_rules c
 ON json_extract(c.payload,'$.app')=json_extract(i.payload,'$.app') AND json_extract(c.payload,'$.type')=json_extract(i.payload,'$.type')
 AND json_extract(c.payload,'$.systemRuleName')=json_extract(i.payload,'$.systemRuleName')
 WHERE (p.action='add' OR (p.action='different' AND '$MODE'='--update')) AND json_extract(c.payload,'$.id')<>p.existing_id;")
[ "$COLLISIONS" = 0 ] || die '解析器名称与其他规则冲突，已在写入前停止'
mkdir -p "$BACKUP_ROOT" || die '无法创建备份目录'
BACKUP="$BACKUP_ROOT/$(date +%Y%m%d_%H%M%S)_$$"
mkdir "$BACKUP" || die '无法创建本次备份目录'
cp "$WORK/before.json" "$BACKUP/安装前规则.json" || die '备份失败'
: > "$WORK/empty"
api '/setting/get?key=setting_js_common' "$WORK/empty" || die '无法读取公共解析脚本'
sql "SELECT writefile('$WORK/active-common.js',coalesce(json_extract(CAST(readfile('$WORK/response.json') AS TEXT),'$.data'),''));" >/dev/null || die '无法解析公共脚本'
cp "$WORK/active-common.js" "$BACKUP/安装前common.js" || die '公共脚本备份失败'
api '/setting/get?key=setting_js_category' "$WORK/empty" || die '无法读取分类脚本'
sql "SELECT writefile('$WORK/active-category.js',coalesce(json_extract(CAST(readfile('$WORK/response.json') AS TEXT),'$.data'),''));" >/dev/null || die '无法解析分类脚本'
cp "$WORK/active-category.js" "$BACKUP/安装前category.js" || die '分类脚本备份失败'
if [ -s "$WORK/active-common.js" ]; then cp "$WORK/active-common.js" "$WORK/validate.js"; else cp "$WORK/common.js" "$WORK/validate.js"; fi
printf '\n' >> "$WORK/validate.js"
sql "SELECT group_concat(json_extract(payload,'$.js'),char(10)) FROM incoming;" >> "$WORK/validate.js" || die '无法生成引擎验证脚本'
sql "SELECT 'if(typeof '||json_extract(payload,'$.systemRuleName')||'!==\"object\"||typeof '||json_extract(payload,'$.systemRuleName')||'.get!==\"function\")throw new Error(\"parser missing\");' FROM incoming;" >> "$WORK/validate.js" || die '无法生成验证条件'
printf '\nif(typeof common.RuleObject!=="function")throw new Error("common library missing");print("AUTO_RULES_VALID_%s");\n' "$COUNT" >> "$WORK/validate.js"
api '/js/run' "$WORK/validate.js" || die '手机解析引擎不兼容或规则无法加载，尚未安装'
MARKER=$(sql "SELECT json_extract(CAST(readfile('$WORK/response.json') AS TEXT),'$.data');")
[ "$MARKER" = "AUTO_RULES_VALID_$COUNT" ] || die '引擎验证未返回预期结果，尚未安装'
ADDS=$(sql "SELECT count(*) FROM plan WHERE action='add';")
DIFFERENT=$(sql "SELECT count(*) FROM plan WHERE action='different';")
echo "手机引擎验证通过：缺少 $ADDS 条，已有 $((COUNT-ADDS)) 条，内容差异 $DIFFERENT 条。"
echo "备份位置：$BACKUP"
printf '模式：%s\n包规则数：%s\n' "$MODE" "$COUNT" > "$BACKUP/安装日志.txt"
if [ "$MODE" = '--check' ]; then echo '仅检查完成，未修改任何规则或公共脚本。'; exit 0; fi
# 只有公共脚本缺失时补齐，不覆盖目标设备已有的公共或分类配置。
if [ ! -s "$WORK/active-common.js" ]; then api '/setting/set?key=setting_js_common' "$WORK/common.js" || die '补齐公共脚本失败'; fi
if [ ! -s "$WORK/active-category.js" ] && [ -s "$WORK/category.js" ]; then api '/setting/set?key=setting_js_category' "$WORK/category.js" || die '补齐分类脚本失败'; fi
sql 'SELECT seq FROM incoming ORDER BY seq;' > "$WORK/indices"
ADDED=0; UPDATED=0; SKIPPED=0; PRESERVED=0
while IFS= read -r seq; do
  action=$(sql "SELECT action FROM plan WHERE seq=$seq;") || die '读取计划失败'
  case "$action" in
    skip) SKIPPED=$((SKIPPED+1)); continue;;
    different)
      if [ "$MODE" != '--update' ]; then PRESERVED=$((PRESERVED+1)); printf '保留内容差异：序号 %s\n' "$seq" >> "$BACKUP/安装日志.txt"; continue; fi
      sql "SELECT writefile('$WORK/payload.json',json_set(i.payload,'$.id',p.existing_id,
       '$.enabled',json(CASE json_extract(c.payload,'$.enabled') WHEN 1 THEN 'true' ELSE 'false' END),
       '$.autoRecord',json(CASE json_extract(c.payload,'$.autoRecord') WHEN 1 THEN 'true' ELSE 'false' END),
       '$.updateAt',CAST(strftime('%s','now') AS INTEGER)*1000)) FROM incoming i JOIN plan p ON i.seq=p.seq
       JOIN current_rules c ON json_extract(c.payload,'$.id')=p.existing_id WHERE i.seq=$seq;" >/dev/null || die '生成更新数据失败'
      api '/rule/update' "$WORK/payload.json" || die "更新序号 $seq 失败"
      UPDATED=$((UPDATED+1));;
    add)
      sql "SELECT writefile('$WORK/payload.json',payload) FROM incoming WHERE seq=$seq;" >/dev/null || die '生成新增数据失败'
      api '/rule/add' "$WORK/payload.json" || die "添加序号 $seq 失败"
      NEW_ID=$(sql "SELECT json_extract(CAST(readfile('$WORK/response.json') AS TEXT),'$.data');")
      case "$NEW_ID" in ''|*[!0-9]*) die '添加后没有返回有效规则ID';; esac
      ADDED=$((ADDED+1)); printf '新增：序号 %s ID %s\n' "$seq" "$NEW_ID" >> "$BACKUP/安装日志.txt";;
    *) die '未知安装动作';;
  esac
done < "$WORK/indices"
api '/rule/list?page=1&limit=10000' || die '安装后读回失败'
cp "$WORK/response.json" "$BACKUP/安装后规则.json" || die '保存读回结果失败'
sql "CREATE TABLE after_rules(payload TEXT);INSERT INTO after_rules SELECT value FROM json_each(CAST(readfile('$WORK/response.json') AS TEXT),'$.data');" || die '无法解析读回结果'
MISSING=$(sql "SELECT count(*) FROM incoming i WHERE (SELECT count(*) FROM after_rules a WHERE json_extract(a.payload,'$.app')=json_extract(i.payload,'$.app')
 AND json_extract(a.payload,'$.type')=json_extract(i.payload,'$.type') AND json_extract(a.payload,'$.creator')=json_extract(i.payload,'$.creator')
 AND json_extract(a.payload,'$.name')=json_extract(i.payload,'$.name'))<>1;")
[ "$MISSING" = 0 ] || die '读回检查发现缺失或重复规则'
WRONG=$(sql "SELECT count(*) FROM incoming i JOIN plan p ON p.seq=i.seq JOIN after_rules a ON json_extract(a.payload,'$.app')=json_extract(i.payload,'$.app')
 AND json_extract(a.payload,'$.type')=json_extract(i.payload,'$.type') AND json_extract(a.payload,'$.creator')=json_extract(i.payload,'$.creator')
 AND json_extract(a.payload,'$.name')=json_extract(i.payload,'$.name') WHERE (p.action='add' OR (p.action='different' AND '$MODE'='--update'))
 AND (json_extract(a.payload,'$.js')<>json_extract(i.payload,'$.js') OR json_extract(a.payload,'$.systemRuleName')<>json_extract(i.payload,'$.systemRuleName'));")
[ "$WRONG" = 0 ] || die '规则内容读回不一致'
TOTAL=$(sql 'SELECT count(*) FROM after_rules;')
SUMMARY="安装完成：新增 $ADDED，更新 $UPDATED，跳过 $SKIPPED，保留差异 $PRESERVED；当前总规则 $TOTAL 条。"
echo "$SUMMARY"
echo "$SUMMARY" >> "$BACKUP/安装日志.txt"
echo '未删除其他规则，未修改已有规则开关，未重跑历史账单，无需重启。'
