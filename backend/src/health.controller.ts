import { Controller, Get } from '@nestjs/common';

const HEALTH_RESPONSE = {
  status: 'ok',
  service: 'help24-backend',
};

@Controller('health')
export class HealthController {
  @Get()
  check() {
    return { ...HEALTH_RESPONSE, timestamp: new Date().toISOString() };
  }
}

@Controller()
export class RootController {
  @Get()
  root() {
    return { ...HEALTH_RESPONSE, timestamp: new Date().toISOString() };
  }
}
