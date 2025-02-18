#!/bin/bash
# 切换到 /root/H2 目录
cd /root/H2 || { echo "目录 /root/H2 不存在！"; exit 1; }

# 遍历目录下所有的 .json 文件
found=0
for json_file in *.json; do
    if [[ -f "$json_file" ]]; then
        found=1
        echo "正在启动客户端配置: $json_file"
        nohup /usr/local/bin/hysteria -c "$PWD/$json_file" >/dev/null 2>&1 &
        echo "已启动: $json_file"
    fi
done

if [[ $found -eq 0 ]]; then
    echo "在 /root/H2 下没有找到 .json 文件"
fi

