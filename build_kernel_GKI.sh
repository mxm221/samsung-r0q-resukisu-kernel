#!/bin/bash

#1. target config
BUILD_TARGET=r0q_gbl_openx
export MODEL=$(echo ${BUILD_TARGET} | cut -d'_' -f1)
export PROJECT_NAME=${MODEL}
export REGION=$(echo ${BUILD_TARGET} | cut -d'_' -f2)
export CARRIER=$(echo ${BUILD_TARGET} | cut -d'_' -f3)
export TARGET_BUILD_VARIANT= user
                        
#2. Chipset common config
CHIPSET_NAME=waipio
export ANDROID_BUILD_TOP=$(pwd)
export TARGET_PRODUCT=gki
export TARGET_BOARD_PLATFORM=gki

export ANDROID_PRODUCT_OUT=${ANDROID_BUILD_TOP}/out/target/product/${MODEL}
export OUT_DIR=${ANDROID_BUILD_TOP}/out/msm-${CHIPSET_NAME}-${CHIPSET_NAME}-${TARGET_PRODUCT}

# for Lcd(techpack) driver build
export KBUILD_EXTRA_SYMBOLS=${ANDROID_BUILD_TOP}/out/vendor/qcom/opensource/mmrm-driver/Module.symvers

# for Audio(techpack) driver build
export MODNAME=audio_dlkm

export KBUILD_EXT_MODULES="../vendor/qcom/opensource/datarmnet-ext/wlan                           ../vendor/qcom/opensource/datarmnet/core                           ../vendor/qcom/opensource/mmrm-driver                           ../vendor/qcom/opensource/audio-kernel                           ../vendor/qcom/opensource/camera-kernel                           ../vendor/qcom/opensource/display-drivers/msm                         "

echo "[+] Applying kernel-level fake boottime offset (30-40d)"
python3 - <<'PY'
from pathlib import Path

p = Path("kernel_platform/common/kernel/time/timekeeping.c")
s = p.read_text()

if "codex_fake_boottime_offset_ns" not in s:
    anchor = '#define TK_CLOCK_WAS_SET\t(1 << 2)\n'
    if anchor not in s:
        raise SystemExit("timekeeping.c patch anchor not found")
    helper = r'''

#define CODEX_FAKE_UPTIME_MIN_SECONDS 2592000ULL
#define CODEX_FAKE_UPTIME_SPAN_SECONDS 864000ULL

static u64 codex_fake_boottime_offset;

static u64 codex_fake_boottime_offset_ns(void)
{
	u64 offset_ns = READ_ONCE(codex_fake_boottime_offset);
	u64 seconds;
	u32 random;

	if (likely(offset_ns))
		return offset_ns;

	random = get_random_u32();
	seconds = CODEX_FAKE_UPTIME_MIN_SECONDS +
		  (random % CODEX_FAKE_UPTIME_SPAN_SECONDS);

	if ((seconds % 60) == 0)
		seconds += 37;
	if ((seconds % 3600) == 0)
		seconds += 97;

	offset_ns = seconds * NSEC_PER_SEC;
	WRITE_ONCE(codex_fake_boottime_offset, offset_ns);

	pr_info("codex_fake_uptime: boottime offset=%llu seconds\n", seconds);
	return offset_ns;
}

static ktime_t codex_apply_fake_boottime(enum tk_offsets offs, ktime_t value)
{
	if (offs == TK_OFFS_BOOT)
		return ktime_add_ns(value, codex_fake_boottime_offset_ns());

	return value;
}
'''
    s = s.replace(anchor, anchor + helper, 1)

old = s
s = s.replace(
    "return (ktime_get_mono_fast_ns() + ktime_to_ns(tk->offs_boot));",
    "return ktime_get_mono_fast_ns() + ktime_to_ns(tk->offs_boot) +\n\t\tcodex_fake_boottime_offset_ns();",
)
if old == s and "codex_fake_boottime_offset_ns();" not in s:
    raise SystemExit("ktime_get_boot_fast_ns patch point not found")

old = s
s = s.replace(
    "return ktime_add_ns(base, nsecs);\n\n}\nEXPORT_SYMBOL_GPL(ktime_get_with_offset);",
    "return codex_apply_fake_boottime(offs, ktime_add_ns(base, nsecs));\n\n}\nEXPORT_SYMBOL_GPL(ktime_get_with_offset);",
)
if old == s and "return codex_apply_fake_boottime(offs, ktime_add_ns(base, nsecs));\n\n}\nEXPORT_SYMBOL_GPL(ktime_get_with_offset);" not in s:
    raise SystemExit("ktime_get_with_offset patch point not found")

old = s
s = s.replace(
    "return ktime_add_ns(base, nsecs);\n}\nEXPORT_SYMBOL_GPL(ktime_get_coarse_with_offset);",
    "return codex_apply_fake_boottime(offs, ktime_add_ns(base, nsecs));\n}\nEXPORT_SYMBOL_GPL(ktime_get_coarse_with_offset);",
)
if old == s and "return codex_apply_fake_boottime(offs, ktime_add_ns(base, nsecs));\n}\nEXPORT_SYMBOL_GPL(ktime_get_coarse_with_offset);" not in s:
    raise SystemExit("ktime_get_coarse_with_offset patch point not found")

p.write_text(s)
PY

#3. build kernel
RECOMPILE_KERNEL=1 ./kernel_platform/build/android/prepare_vendor.sh sec ${TARGET_PRODUCT}
