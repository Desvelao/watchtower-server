import { createGetterSetter } from '../../services/create_getter_setter';

export const [getServices, setServices] =
  createGetterSetter('scrapers_services');
