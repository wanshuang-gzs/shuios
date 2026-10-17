cmake_minimum_required(VERSION 3.16)

project(shuios
    VERSION 0.1.0
    DESCRIPTION "氵系统 - An AI-native desktop environment"
    LANGUAGES CXX C)

# ── 标准与编译选项 ────────────────────────────────────────
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

set(CMAKE_CXX_FLAGS_RELEASE "-O2 -DNDEBUG")
add_compile_options(-Wall -Wextra -Wno-unused-parameter)

# ── Qt6 依赖 ──────────────────────────────────────────────
# 注意: WaylandCompositor 是 GPLv3-only，本项目整体采用 GPLv3
find_package(Qt6 REQUIRED COMPONENTS
    Core
    Gui
    Qml
    Quick
    QuickControls2
    WaylandCompositor
    Network
)

qt_standard_project_setup()
qt_policy(SET QTP0001 NEW)

# ── 源文件 ────────────────────────────────────────────────
set(SHUIOS_SOURCES
    src/main.cpp

    # 核心
    src/core/Config.cpp
    src/core/Log.cpp

    # 身体: 合成器
    src/compositor/ShimCompositor.cpp
    src/compositor/WindowManager.cpp

    # 权限内核
    src/capability/CapabilityStore.cpp
    src/capability/Ledger.cpp

    # 意图
    src/intent/IntentParser.cpp

    # 执行
    src/actions/ActionRegistry.cpp
    src/actions/FileActions.cpp
    src/actions/Trash.cpp

    # 大脑接口
    src/brain/BrainClient.cpp
    src/brain/DeepSeekProvider.cpp
)

set(SHUIOS_HEADERS
    src/core/Config.h
    src/core/Log.h

    src/compositor/ShimCompositor.h
    src/compositor/WindowManager.h

    src/capability/CapabilityStore.h
    src/capability/Ledger.h

    src/intent/Plan.h
    src/intent/IntentParser.h

    src/actions/Action.h
    src/actions/ActionRegistry.h
    src/actions/FileActions.h
    src/actions/Trash.h

    src/brain/Message.h
    src/brain/BrainClient.h
    src/brain/DeepSeekProvider.h
)

# ── 可执行文件 ────────────────────────────────────────────
qt_add_executable(shuios ${SHUIOS_SOURCES} ${SHUIOS_HEADERS})

target_include_directories(shuios PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# ── QML 模块 ──────────────────────────────────────────────
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
    Qt6::WaylandCompositor
    Qt6::Network
)

# ── 安装规则 ──────────────────────────────────────────────
include(GNUInstallDirs)

install(TARGETS shuios
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

# Wayland 会话启动文件: 让登录管理器能选 "氵系统" 会话
install(FILES packaging/session/shuios.desktop
    DESTINATION ${CMAKE_INSTALL_DATADIR}/wayland-sessions
)

# 应用菜单项
install(FILES packaging/shuios-app.desktop
    DESTINATION ${CMAKE_INSTALL_DATADIR}/applications
)

# ── 测试 ──────────────────────────────────────────────────
enable_testing()
add_subdirectory(tests)

# ── 打包信息 ──────────────────────────────────────────────
set(CPACK_PACKAGE_NAME "shuios")
set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION})
set(CPACK_PACKAGE_CONTACT "shuios project")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "氵系统 - AI-native desktop environment")
set(CPACK_DEBIAN_PACKAGE_DEPENDS
    "libqt6core6, libqt6gui6, libqt6qml6, libqt6quick6, libqt6quickcontrols2-6, libqt6waylandcompositor6, libqt6network6")
set(CPACK_GENERATOR "DEB")
include(CPack)