#!/bin/bash
# Orange Pi display feasibility spike (Phase 2 / Phase 3 gate).
#
# Run this ON the target board (over a plain Armbian image, or an RPi-Mac Orange
# Pi image) to prove the appliance's core display path BEFORE relying on it:
#
#   SDL2 + SDL_VIDEODRIVER=kmsdrm + GLES2  on  sun4i-drm + Mesa Panfrost.
#
# That is exactly what Basilisk II needs. It is the make-or-break risk for the
# sunxi Orange Pi family (Zero 2/2W/3, Mali-G31) and the harder gate for the
# Orange Pi Zero 3W (Allwinner A733 / PowerVR, vendor blob - no Panfrost).
#
# Read-only and self-contained; installs a couple of test packages with sudo.
# Exit code 0 means the KMSDRM + GLES2 clear-screen test ran; non-zero means the
# path does not work as-is and the build should not depend on it yet.
set -u

PASS=0
FAIL=1

section() { printf '\n===== %s =====\n' "$1"; }

section "Board / kernel"
if command -v rpimac-detect-board > /dev/null 2>&1; then
	rpimac-detect-board
elif [ -r /proc/device-tree/model ]; then
	tr '\000' ' ' < /proc/device-tree/model; echo
fi
uname -a

section "DRM devices and connectors"
ls -l /dev/dri/ 2> /dev/null || echo "no /dev/dri (no DRM device!)"
for S in /sys/class/drm/card*-*/status; do
	[ -e "${S}" ] && echo "${S}: $(cat "${S}")"
done
echo "DRM drivers in use:"
for D in /sys/class/drm/card*/device/driver; do
	[ -e "${D}" ] && echo "  $(basename "$(dirname "$(dirname "${D}")")") -> $(basename "$(readlink -f "${D}")")"
done

section "GPU kernel driver (expect panfrost on Mali sunxi)"
if lsmod | grep -Eq 'panfrost|lima'; then
	lsmod | grep -E 'panfrost|lima'
else
	echo "panfrost/lima not in lsmod (may be built-in); checking dmesg:"
	dmesg 2> /dev/null | grep -iE 'panfrost|lima|mali|powervr|pvr' | tail -n 10 \
		|| echo "  no GPU driver messages found"
fi

section "Installing test tools (mesa-utils, kmscube, SDL2 dev)"
if command -v sudo > /dev/null 2>&1; then
	sudo apt-get update -qq || true
	sudo apt-get install -y --no-install-recommends mesa-utils kmscube libsdl2-dev gcc libc6-dev > /dev/null 2>&1 || true
fi

section "Mesa GLES renderer (es2_info)"
if command -v es2_info > /dev/null 2>&1; then
	es2_info 2>&1 | grep -iE 'GL_RENDERER|GL_VERSION|GL_VENDOR|EGL' | head -n 8 \
		|| echo "es2_info produced no GL strings"
else
	echo "es2_info not available"
fi

section "kmscube (KMSDRM + GLES smoke test, 3s)"
if command -v kmscube > /dev/null 2>&1; then
	timeout 3 kmscube 2>&1 | tail -n 15 || echo "kmscube exited (timeout/own); review output above"
else
	echo "kmscube not installed; skipping"
fi

section "SDL2 KMSDRM + GLES2 clear-screen test"
TESTDIR="$(mktemp -d)"
cat > "${TESTDIR}/sdl_gles_test.c" << 'CEOF'
#include <stdio.h>
#include <SDL.h>
#include <SDL_opengles2.h>
int main(void) {
    if (SDL_Init(SDL_INIT_VIDEO) != 0) { printf("SDL_Init failed: %s\n", SDL_GetError()); return 2; }
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
    SDL_Window *w = SDL_CreateWindow("rpimac-spike", 0, 0, 640, 480,
                                     SDL_WINDOW_OPENGL | SDL_WINDOW_FULLSCREEN_DESKTOP);
    if (!w) { printf("CreateWindow failed: %s\n", SDL_GetError()); SDL_Quit(); return 3; }
    SDL_GLContext ctx = SDL_GL_CreateContext(w);
    if (!ctx) { printf("GL_CreateContext failed: %s\n", SDL_GetError()); SDL_DestroyWindow(w); SDL_Quit(); return 4; }
    const char *ven = (const char *)glGetString(GL_VENDOR);
    const char *ren = (const char *)glGetString(GL_RENDERER);
    const char *ver = (const char *)glGetString(GL_VERSION);
    printf("GL_VENDOR=%s\nGL_RENDERER=%s\nGL_VERSION=%s\n",
           ven ? ven : "(null)", ren ? ren : "(null)", ver ? ver : "(null)");
    for (int i = 0; i < 60; i++) {
        glClearColor((i % 2) ? 0.0f : 0.6f, 0.6f, 0.6f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        SDL_GL_SwapWindow(w);
        SDL_Delay(16);
    }
    int ok = (ren != NULL);
    SDL_GL_DeleteContext(ctx);
    SDL_DestroyWindow(w);
    SDL_Quit();
    printf("%s\n", ok ? "SDL_GLES2_OK" : "SDL_GLES2_NO_RENDERER");
    return ok ? 0 : 5;
}
CEOF

RESULT="${FAIL}"
if command -v sdl2-config > /dev/null 2>&1 && command -v gcc > /dev/null 2>&1; then
	if gcc "${TESTDIR}/sdl_gles_test.c" -o "${TESTDIR}/sdl_gles_test" \
		$(sdl2-config --cflags --libs) -lGLESv2 2> "${TESTDIR}/build.log"; then
		echo "compiled SDL2 GLES2 test; running under kmsdrm..."
		if SDL_VIDEODRIVER=kmsdrm "${TESTDIR}/sdl_gles_test"; then
			RESULT="${PASS}"
		fi
	else
		echo "failed to compile SDL2 test:"
		cat "${TESTDIR}/build.log"
	fi
else
	echo "sdl2-config or gcc missing; cannot run the SDL2 test"
fi
rm -rf "${TESTDIR}"

section "Result"
if [ "${RESULT}" -eq "${PASS}" ]; then
	echo "PASS: SDL2 + kmsdrm + GLES2 works on this board. The RPi-Mac display"
	echo "path is feasible here; proceed with the Orange Pi build."
else
	echo "FAIL: the SDL2 + kmsdrm + GLES2 path did not work. Do NOT ship an"
	echo "image that depends on it. Try a different kernel BRANCH (edge),"
	echo "confirm the GPU driver (Panfrost for Mali; PowerVR blob for the A733"
	echo "Zero 3W), and that an HDMI display is connected."
fi
exit "${RESULT}"
