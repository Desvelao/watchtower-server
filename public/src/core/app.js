import router from './router';
import './style.css';
import { AppService } from './services/app-service';
import { http } from '../services/api/http';

const appService = new AppService(router);

export default {
  router,
  appService,
  http,
};
