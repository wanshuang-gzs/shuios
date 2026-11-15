# shuios BR2_EXTERNAL 入口
#
# 约定：BR2_EXTERNAL_SHUIOS_PATH 由 external.desc 里的 name: SHUIOS 推出
# （Buildroot 逐字使用 external.desc 的 name：name: SHUIOS -> BR2_EXTERNAL_SHUIOS_PATH）
include $(sort $(wildcard $(BR2_EXTERNAL_SHUIOS_PATH)/package/*/*.mk))
