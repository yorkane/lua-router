# Lua router on top of the authz gateway image.
#
# authz:latest already ships OpenResty 1.31.1.1 with PCRE2/JIT, klib.router,
# lua-resty-lock, lua-resty-template, resty.openssl and the brotli/gzip stack, so
# the Lua router adds only its own modules, config template and entrypoint.
#
#   docker build -t lua-router:latest .
#
# The build context is the *repo root* (.. from lua-router) so the shared lualib
# tree stays available to the image if a later module needs it:
#   docker build -t lua-router:latest -f Dockerfile .

FROM authz:latest AS final

# Project Lua: resty/luarouter/* lands next to klib/* in the site prefix, which
# is first on the lua_package_path the template renders.
# Whole lualib tree, so a module added later cannot be missing from the image.
COPY lualib/ /usr/local/openresty/site/lualib/
COPY conf/nginx.conf.template /usr/local/openresty/nginx/conf/nginx.conf.template
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# UI agent's contribution, placed where the entrypoint looks for it. ui.conf is
# included into server{} by the entrypoint only when present, so the router still
# boots if the UI fragment is not built yet. The static bundle lands next to the
# Rust image's path so LMR_UI_DIR does not have to be set.
COPY conf/ui.conf /usr/local/openresty/nginx/conf/lua-router/ui.conf
COPY ui/ /usr/local/share/llama-ui/

# 30000 inference, 29000 Prometheus.
EXPOSE 30000 29000

STOPSIGNAL SIGQUIT

# Build-time gate: render the template exactly as the container will and refuse
# to finish the build if the result does not parse. The entrypoint validates the
# render before it execs the command, so `openresty -t` here exits on the config.
RUN /docker-entrypoint.sh openresty -t -p /usr/local/openresty/nginx

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
