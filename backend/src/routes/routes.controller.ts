import { Body, Controller, Post } from '@nestjs/common';
import { IsLatitude, IsLongitude, IsNumber } from 'class-validator';
import { RoutesService, RouteResult } from './routes.service';

class ComputeRouteDto {
  @IsNumber()
  @IsLatitude()
  originLat!: number;

  @IsNumber()
  @IsLongitude()
  originLng!: number;

  @IsNumber()
  @IsLatitude()
  destLat!: number;

  @IsNumber()
  @IsLongitude()
  destLng!: number;
}

/**
 * POST /routes/compute — ETA, remaining distance and route polyline for an
 * active journey. Proxies Google Routes so the billable key never ships in the
 * app (see RoutesService).
 *
 * Always answers 200. An unavailable route is `{ available: false }`, not an
 * error status: the client treats it as "no ETA yet" and keeps rendering the
 * Phase 2 straight-line experience.
 */
@Controller('routes')
export class RoutesController {
  constructor(private readonly routes: RoutesService) {}

  @Post('compute')
  async compute(@Body() dto: ComputeRouteDto): Promise<RouteResult> {
    return this.routes.computeRoute(
      dto.originLat,
      dto.originLng,
      dto.destLat,
      dto.destLng,
    );
  }
}
