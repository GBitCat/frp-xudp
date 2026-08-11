# FRP XUDP Extension Design Document

版本：v0.1

目标：为 FRP 增加 P2P UDP Proxy 能力。

------------------------------------------------------------------------

# 1. 项目目标

## 1.1 功能目标

新增代理类型：

    xudp

支持：

    内网服务
        |
       frpc
        |
     UDP Hole Punch
        |
       frpc
        |
    客户端

区别于传统 UDP proxy：

传统：

    Client
      |
    frps
      |
    frpc
      |
    Service

XUDP：

    Client
      |
    frpc
      |
    UDP P2P
      |
    frpc
      |
    Service

------------------------------------------------------------------------

# 2. 总体架构

                             Control Plane

                         +-------------+
                         |    frps     |
                         | XUDP Broker |
                         +-------------+

                           /        \

                     frpc-A          frpc-B

                      |                |

                 XUDP Agent      XUDP Agent

                      \                /

                        UDP Hole Punch

                              |

                         Direct UDP

------------------------------------------------------------------------

# 3. 模块划分

    frp/

    ├── pkg/
    │
    ├── proxy/
    │    ├── tcp.go
    │    ├── udp.go
    │    └── xudp.go
    │
    ├── xudp/
    │    ├── stun/
    │    │     └── client.go
    │    ├── punch/
    │    │     └── hole.go
    │    ├── session/
    │    │     └── table.go
    │    └── relay/
    │          └── fallback.go
    │
    ├── client/
    │    └── xudp_client.go
    │
    └── server/
         └── xudp_server.go

------------------------------------------------------------------------

# 4. 配置设计

frpc.toml：

``` toml
[[proxies]]

name = "game"

type = "xudp"

localIP = "127.0.0.1"

localPort = 2000

remotePort = 2000

[xudp]

enableP2P = true

fallbackRelay = true

stunServer = [
 "stun.example.com:3478"
]
```

------------------------------------------------------------------------

# 5. Proxy生命周期

流程：

1.  frpc 登录 frps
2.  注册 xudp proxy
3.  frps 保存节点信息
4.  请求连接时交换 endpoint
5.  尝试 UDP 打洞
6.  成功后进入 P2P
7.  失败后回退 relay

------------------------------------------------------------------------

# 6. 控制协议扩展

新增：

## XUDP_REGISTER

客户端注册：

``` json
{
 "proxy":"game",
 "node":"A",
 "publicKey":"xxx"
}
```

## XUDP_CONNECT

请求连接：

``` json
{
 "target":"game"
}
```

## XUDP_OFFER

返回 peer 地址：

``` json
{
 "peer":{
   "ip":"8.8.8.8",
   "port":45000
 }
}
```

------------------------------------------------------------------------

# 7. NAT 穿透流程

## STUN 地址发现

frpc 查询公网映射：

    192.168.1.20:5000

            NAT

    203.0.113.1:45000

------------------------------------------------------------------------

## UDP Hole Punch

双方同时发送：

    A ---------------- B

           UDP Probe

    A <--------------- B

成功后建立：

    A <=========> B

        Direct UDP

------------------------------------------------------------------------

# 8. Session 管理

UDP 无连接，需要维护：

    Session Table

    Session ID

    Client Addr

    Peer Addr

    Last Active

    State

状态：

    INIT

    PUNCHING

    CONNECTED

    TIMEOUT

------------------------------------------------------------------------

# 9. 数据模式

## P2P模式

    frpc-A

       UDP

    frpc-B

## Relay模式

失败时：

    A

    |

    frps

    |

    B

------------------------------------------------------------------------

# 10. NAT 类型处理

支持检测：

-   Full Cone
-   Restricted Cone
-   Port Restricted
-   Symmetric NAT

策略：

  类型         策略
  ------------ -----------
  Full Cone    P2P
  Restricted   尝试打洞
  Symmetric    优先Relay

------------------------------------------------------------------------

# 11. Keepalive

建立连接后：

每 20\~30 秒发送：

    PING

防止 NAT 映射过期。

------------------------------------------------------------------------

# 12. 安全设计

Probe 包需要：

-   session token
-   timestamp
-   HMAC

防止：

-   UDP伪造
-   会话劫持

------------------------------------------------------------------------

# 13. 兼容官方 FRP

使用能力协商：

``` json
{
 "features":[
   "xudp"
 ]
}
```

兼容策略：

  frpc   frps   结果
  ------ ------ ------
  旧     旧     正常
  新     新     XUDP
  新     旧     降级

------------------------------------------------------------------------

# 14. 开发阶段

## Phase 1

完成：

-   xudp proxy
-   控制协议
-   UDP relay

## Phase 2

增加：

-   STUN
-   endpoint交换
-   UDP punch

## Phase 3

增加：

-   NAT检测
-   fallback
-   session管理

## Phase 4

优化：

-   IPv6
-   多节点
-   移动网络

------------------------------------------------------------------------

# 15. 难度评估

  模块        难度
  ----------- ------
  新增proxy   低
  配置扩展    低
  控制协议    中
  STUN        中
  UDP打洞     中高
  NAT兼容     高

------------------------------------------------------------------------

# 16. 推荐路线

第一版：

    FRP
    +
    XUDP Proxy
    +
    STUN
    +
    UDP Hole Punch
    +
    Relay fallback

目标：

实现 FRP 端口映射模型与 P2P UDP 传输结合。
