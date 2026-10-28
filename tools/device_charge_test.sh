#!/system/bin/sh
# 真机充电链路自测：温控 mask -> 守卫 -> 加速 -> 还原，全程可逆。
MODDIR=${MODDIR:-/data/local/tmp/rm-test-302}
export MODDIR
. "$MODDIR/paths.sh"
. "$MODDIR/common.sh"
for _f in system thermal fanpump charge touch bright state status; do
    . "$MODDIR/lib/$_f.sh"
done
SILENT=1

show() {
    local n v
    for n in restrict_cur restrict_chg charging_enabled battery_charging_enabled charge_control_en; do
        v=$(chg_val "$n" 2>/dev/null)
        printf '%s=%s ' "$n" "${v:-NA}"
    done
    echo
}

echo "== before =="
show
echo "ac=$(rdv "$AC_ONLINE") sep=$(sep_now) temp=$(battery_temp_deg)"

echo "== thermal =="
thermal_on && echo THERMAL_ON || echo THERMAL_FAIL
thermal_effective && echo THERMAL_EFF || echo THERMAL_NOT_EFF

echo "== boost =="
boost_guard && echo GUARD_OK || echo GUARD_FAIL
: > "$F_BOOST"
boost_apply && echo BOOST_OK || echo BOOST_FAIL
boost_effective && echo BOOST_EFF || echo BOOST_NOT_EFF
show

echo "== heat =="
heat_apply && echo HEAT_OK || echo HEAT_FAIL
d=$(heat_find) && { printf '%s ' "$d"; cat "$d/type" "$d/cur_state"; }

echo "== release =="
boost_release && echo RELEASE_OK
show
heat_release && echo HEAT_RELEASE_OK
thermal_off && echo THERMAL_OFF

echo "== after =="
show
thermal_effective && echo STILL_EFF || echo NOT_EFF
