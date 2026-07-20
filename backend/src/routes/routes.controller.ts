import { Body, Controller, HttpCode, HttpStatus, Ip, Post } from '@nestjs/common';
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

  // 200, not Nest's default 201 for POST: this computes and returns a value,
  // it does not create a resource. POST is used only because the request
  // carries a coordinate body. (Verified in the field: the client treated the
  // 201 as a failure and silently dropped every successful route.)
  @Post('compute')
  @HttpCode(HttpStatus.OK)
  async compute(
    @Body() dto: ComputeRouteDto,
    @Ip() ip: string,
  ): Promise<RouteResult> {
    // The caller IP is the only identity available here — the endpoint is
    // unauthenticated by necessity — and it is what the per-caller spend
    // budget is keyed on. Render sits behind a proxy, so trust proxy must be
    // enabled for this to be the real client address rather than the edge's.
    return this.routes.computeRoute(
      dto.originLat,
      dto.originLng,
      dto.destLat,
      dto.destLng,
      ip || 'unknown',
    );
  }
}
