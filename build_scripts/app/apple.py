import os

from app.builder import Builder
from app.command_line import run_command


class AppleBuilder(Builder):
    def before_build(self):
        super().before_build()
        self.build_core()
        self.update_build_number()
        self.update_pod()

    def update_build_number(self):
        run_command(
            ["xcrun", "agvtool", "new-version", "-all", str(self.build_number)],
            cwd=self.project_dir,
        )

    def update_pod(self):
        run_command(["pod", "repo", "update"], cwd=self.project_dir)

    def build_app(self):
        # SKIP_FASTLANE=1 — bypass fastlane (no signing/notarization).
        # Useful for local testing without Apple certs. Just runs
        # `flutter build macos` (or ios) — produces unsigned .app bundle
        # at build/<platform>/Build/Products/Release/.
        # Note: macOS xcconfig files (macos/Runner/Configs/{Debug,Release}.xcconfig)
        # have CODE_SIGNING_ALLOWED=NO that disables signing at xcodebuild
        # level. iOS would need --no-codesign flag (which is iOS-only).
        if os.environ.get("SKIP_FASTLANE"):
            print("[apple] SKIP_FASTLANE=1 — running `flutter build` without fastlane")
            build_target = "macos" if self.system in ("macos", "macos_se") else "ios"
            cmd = ["flutter", "build", build_target]
            if self.system == "ios":
                # iOS supports --no-codesign (macOS doesn't)
                cmd.append("--no-codesign")
            run_command(cmd, cwd=os.path.dirname(self.project_dir))
            return
        run_command(["fastlane", self.fastlane, "--verbose"], cwd=self.project_dir)
