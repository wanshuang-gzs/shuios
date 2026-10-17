cmake_minimum_required(VERSION 3.16)

project(shuios
    VERSION 0.1.0
    DESCRIPTION "氵系统 - An AI-native desktop environment"
    LANGUAGES CXX C)

# ── 标准与编译选项 ────────────────────────────────────────
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

add_compile_options(-Wall -Wextra -Wno-unused-parameter)

# ── Qt6 依赖 ──────────────────────────────────────────────
# WaylandCompositor 是 GPLv3-only，本项目整体采用 GPLv3
find_package(Qt6 REQUIRED COMPONENTS
    Core
    Gui
    Qml
    Quick
    QuickControls2
    Network
)

# WaylandCompositor 单独查找，便于给出清晰错误
find_package(Qt6 REQUIRED COMPONENTS WaylandCompositor)

# 版本下限检查。Qt 6.7 由 CI 提供；6.4 起可配置，
# 但部分 WaylandCompositor QML 类型需要 6.5+，见 README。
if(Qt6_VERSION VERSION_LESS 6.4)
    message(FATAL_ERROR "需要 Qt 6.4 或更高版本，当前为 ${Qt6_VERSION}")
endif()
message(STATUS "Qt 版本: ${Qt6_VERSION}")
if(Qt6_VERSION VERSION_LESS 6.5)
    message(WARNING "Qt ${Qt6_VERSION} < 6.5：部分 WaylandCompositor QML API 可能缺失")
endif()

qt_standard_project_setup()

# ── 源文件 ────────────────────────────────────────────────
set(SHUIOS_SOURCES
    src/main.cpp

    src/core/Config.cpp
    src/core/Log.cpp

    src/compositor/ShimCompositor.cpp
    src/compositor/WindowManager.cpp

    src/capability/CapabilityStore.cpp
    src/capability/Ledger.cpp

    src/intent/IntentParser.cpp

    src/actions/ActionRegistry.cpp
    src/actions/FileActions.cpp
    src/actions/Trash.cpp

    src/brain/DeepSeekProvider.cpp
)

# ── 可执行文件 ────────────────────────────────────────────
qt_add_executable(shuios ${SHUIOS_SOURCES})

target_include_directories(shuios PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# ── QML 模块 ──────────────────────────────────────────────
# 注意: QML 源文件放在 qml/ 下，qt_add_qml_module 会自动生成
# "qrc:/qt/qml/Shuios/..." 路径，与 loadFromModule("Shuios","Main") 对应。
qt_add_qml_module(shuios
    URI Shuios
    VERSION 1.0
    QML_FILES
        qml/main.qml
        qml/ConversationView.qml
        qml/PlanConfirmDialog.qml
        qml/Taskbar.qml
        qml/components/MessageBubble.qml
        qml/components/CapabilityBadge.qml
)

target_link_libraries(shuios PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Network
    Qt6::WaylandCompositor
)

# ── 安装规则 ──────────────────────────────────────────────
include(GNUInstallDirs)

install(TARGETS shuios
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

install(FILES packaging/session/shuios.desktop
    DESTINATION ${CMAKE_INSTALL_DATADIR}/wayland-sessions
)

install(FILES packaging/shuios-app.desktop
    DESTINATION ${CMAKE_INSTALL_DATADIR}/applications
)

# ── 测试 ──────────────────────────────────────────────────
enable_testing()
add_subdirectory(tests)

# ── 打包 ──────────────────────────────────────────────────
set(CPACK_PACKAGE_NAME "shuios")
set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION})
set(CPACK_PACKAGE_CONTACT "shuios project")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "氵系统 - AI-native desktop environment")
set(CPACK_DEBIAN_PACKAGE_DEPENDS
    "libqt6core6, libqt6gui6, libqt6qml6, libqt6quick6, libqt6quickcontrols2-6, libqt6waylandcompositor6, libqt6network6")
set(CPACK_GENERATOR "DEB")
include(CPack)