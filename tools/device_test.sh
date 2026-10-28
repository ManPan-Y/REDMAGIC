#!/system/bin/sh
# 真机自测：只碰模块自己的 staging 目录和可还原的触控节点。
MODDIR=${MODDIR:-/data/local/tmp/rm-test}
export MODDIR
. "$MODDIR/paths.sh"
. "$MODDIR/common.sh"
for _f in system thermal fanpump charge touch bright state status; do
    . "$MODDIR/lib/$_f.sh"
done
SILENT=1

echo "== nodes =="
echo "touch_missing=$(touch_missing_nodes)"
echo "rate_current=$(rate_current) rate_target=$(rate_target)"
rd "$BAT_DIR/temp"; echo "temp_raw=$RD"
echo "ac=$(rdv "$AC_ONLINE") sep=$(sep_now)"

echo "== touch before =="
touch_read_field algo_open && echo "algo_open=$TOUCH_RD"
touch_read_field "pixel limit level" && echo "anti=$TOUCH_RD"
touch_read_field long_press_pixel && echo "long_range=$TOUCH_RD"

echo "== apply gaming preset =="
rm -f "$TOUCH_SNAPSHOT"
touch_preset_to_state official_gaming
if touch_apply; then echo "APPLY_OK"; else echo "APPLY_FAIL"; fi
if touch_verify; then echo "VERIFY_OK"; else echo "VERIFY_FAIL"; fi
echo "vals=$(touch_vals_string)"
echo "preset=$(touch_preset_vals official_gaming)"

echo "== restore =="
if touch_restore; then echo "RESTORE_OK"; else echo "RESTORE_FAIL"; fi
for n in follow_hand_level stability_level sensibility tp_report_rate; do
    printf '%s=' "$n"; cat "$TP_DIR/$n"
done
touch_read_field algo_open && echo "algo_open=$TOUCH_RD"
touch_read_field "pixel limit level" && echo "anti=$TOUCH_RD"
touch_read_field long_press_pixel && echo "long_range=$TOUCH_RD"

echo "== status =="
rm -f "$WEBUI_STATUS"
if status_write; then echo "STATUS_OK"; else echo "STATUS_FAIL"; fi
cat "$WEBUI_STATUS" 2>/dev/null
