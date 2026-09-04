export class AppService {
  constructor(router) {
    this.router = router;
    this.__apps = new Map();
    this.__groups = new Map();
  }
  registerApp(app) {
    const { route: path, component, permission, public: isPublic } = app;
    if (this.__apps.has(path)) {
      throw new Error(`Route already registered: [${path}]`);
    }
    this.__apps.set(path, app);
    this.router.addRoute({
      path,
      component,
      meta: { permission, public: isPublic },
    });
  }
  registerGroupApp(group) {
    const { route: path, component } = group;
    if (this.__apps.has(path)) {
      throw new Error(`Route already registered: [${path}]`);
    }
    this.__apps.set(path, group);
    this.router.addRoute({ path, component });
  }
}
