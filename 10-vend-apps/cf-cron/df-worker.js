// cloud-house tick: the cron only calls the Trigger endpoint. url and secret come from Worker bindings.
export default {
  async scheduled(controller, env, ctx) {
    const head = { "x-tick-time": String(controller.scheduledTime) };
    if (env.TICK_SECRET) head[env.SECRET_HEADER] = env.TICK_SECRET;
    ctx.waitUntil(fetch(env.TRIGGER_URL, { method: env.TRIGGER_METHOD, headers: head }));
  },
  async fetch() {
    return new Response("cf-cron ok", { status: 200 });
  },
};
