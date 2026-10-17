set(APP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/app")

# ONEXRAY_WINDOWS_MODE (configure-time environment, set by build_scripts):
# VCore is the MSIX system-VPN backend; the EXE mode never loads it.
set(ONEXRAY_WINDOWS_MODE "$ENV{ONEXRAY_WINDOWS_MODE}")
if(NOT ONEXRAY_WINDOWS_MODE)
  set(ONEXRAY_WINDOWS_MODE "exe")
endif()

install(CODE "file(REMOVE_RECURSE \"${CMAKE_INSTALL_PREFIX}/bin\")"
        COMPONENT Runtime)

# Both distribution modes use the same flat runtime layout. Missing native
# dependencies must fail the build instead of producing an incomplete package.
install(FILES
        "${APP_DIR}/libXray.dll"
        "${APP_DIR}/wintun.dll"
        DESTINATION "${CMAKE_INSTALL_PREFIX}"
        COMPONENT Runtime)

install(PROGRAMS
        "${APP_DIR}/OneXrayCore.exe"
        DESTINATION "${CMAKE_INSTALL_PREFIX}"
        COMPONENT Runtime)

if(ONEXRAY_WINDOWS_MODE STREQUAL "msix")
  install(FILES
          "${APP_DIR}/vcore.dll"
          DESTINATION "${CMAKE_INSTALL_PREFIX}"
          COMPONENT Runtime)
  install(PROGRAMS
          "${APP_DIR}/vcore-windows-vpn-host.exe"
          "${APP_DIR}/vcore-windows-session-host.exe"
          DESTINATION "${CMAKE_INSTALL_PREFIX}"
          COMPONENT Runtime)
endif()
