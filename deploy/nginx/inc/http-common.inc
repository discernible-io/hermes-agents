# Shared http{} settings for hermes nginx TLS sidecar.

large_client_header_buffers 4 16k;
client_max_body_size 10M;
client_body_timeout 30s;
client_body_buffer_size 128k;

limit_req_status 429;

# Rate-limit public ingress; empty key skips limit_req for that request.
map $uri $hermes_health_limit_key {
    default "";
    "~^/health$" $remote_addr;
}

map $uri $hermes_ingress_limit_key {
    default "";
    "~^/webhooks(?:/|$)" $binary_remote_addr;
    "~^/telegram(?:/|$)" $binary_remote_addr;
    "~^/a2a(?:/|$)" $binary_remote_addr;
    "~^/\.well-known/" $binary_remote_addr;
    "~^/api/login(?:/|$)" $binary_remote_addr;
}

map $uri $hermes_public_limit_key {
    default $binary_remote_addr;
    "~^/health$" "";
    "~^/webhooks(?:/|$)" "";
    "~^/telegram(?:/|$)" "";
    "~^/a2a(?:/|$)" "";
    "~^/\.well-known/" "";
    "~^/api/login(?:/|$)" "";
}

limit_req_zone $hermes_health_limit_key zone=hermes_health:10m rate=30r/m;
limit_req_zone $hermes_ingress_limit_key zone=hermes_ingress:20m rate=120r/s;
limit_req_zone $hermes_public_limit_key zone=hermes_public:20m rate=60r/s;

error_page 413 414 = @request_error;

log_format detailed '$remote_addr - $remote_user [$time_local] "$request" '
                   '$status $body_bytes_sent "$http_referer" '
                   '"$http_user_agent" '
                   'request_time=$request_time';
access_log /var/log/nginx/access.log detailed;

ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 10m;

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
