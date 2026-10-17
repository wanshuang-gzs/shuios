cmake_minimum_required(VERSION 3.16)

# ── 作用域匹配测试 ────────────────────────────────────────
# 【最重要的一组】验证权限边界安全:
#   授权 /home/user/docs 后，/home/user/docs_evil 必须被拒绝。
#   如果这里退化成简单的 startsWith()，就是权限逃逸漏洞。
add_executable(test_scope_match test_scope_match.cpp
    ../src/capability/CapabilityStore.cpp
    ../src/capability/Ledger.cpp
    ../src/core/Log.cpp
)
target_include_directories(test_scope_match PRIVATE ../src)
target_link_libraries(test_scope_match PRIVATE Qt6::Core)

add_test(NAME scope_match COMMAND test_scope_match)

# ── 意图解析测试 ──────────────────────────────────────────
add_executable(test_intent test_intent.cpp
    ../src/intent/IntentParser.cpp
    ../src/capability/CapabilityStore.cpp
    ../src/capability/Ledger.cpp
    ../src/core/Log.cpp
)
target_include_directories(test_intent PRIVATE ../src)
target_link_libraries(test_intent PRIVATE Qt6::Core)

add_test(NAME intent COMMAND test_intent)