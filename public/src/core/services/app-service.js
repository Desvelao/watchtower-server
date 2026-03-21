export class AppService {
  constructor(router) {
    this.router = router;
    this.__apps = new Map();
    this.__groups = new Map();
  }
  registerApp(app) {
    const { route: path, component } = app;
    if (this.__apps.has(path)) {
      throw new Error(`Route already registered: [${path}]`);
    }
    this.__apps.set(path, app);
    this.router.addRoute({ path, component });
  }
  registerGroupApp(group) {
    const { route: path, component } = app;
    if (this.__apps.has(path)) {
      throw new Error(`Route already registered: [${path}]`);
    }
    this.__apps.set(path, app);
    this.router.addRoute({ path: route, component });
  }
}
