FROM ubuntu:24.04

# 设置非交互模式，避免 tzdata 等包安装时卡住
ENV DEBIAN_FRONTEND=noninteractive

# 更新并安装依赖
RUN apt-get update && apt-get upgrade -y && apt-get install -y \
    gcc \
    make \
    wget \
    perl \
    procps \
    build-essential \
    libreadline-dev \
    libncurses5-dev \
    libpcre3-dev \
    libssl-dev \
    python3 \
    python3-pip \
    python3-setuptools \
    && rm -rf /var/lib/apt/lists/*

# 创建目录
RUN mkdir /code
COPY ./ /code/
WORKDIR /code

# 创建 nginx 用户组
RUN groupadd -r nginx && useradd -r -g nginx nginx

# 安装 Python 依赖
RUN python3 install.py install

# 暴露端口
EXPOSE 80

# 启动命令
CMD ["/opt/verynginx/openresty/nginx/sbin/nginx", "-g", "daemon off; error_log /dev/stderr info;"]