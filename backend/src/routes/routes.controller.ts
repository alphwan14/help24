import { Body, Controller, HttpCode, HttpStatus, Ip, Post } from '@nestjs/common';
import { IsLatitude, IsLongitude, IsNumber } from 'class-validator';
import { RoutesService, RouteResult } from './routes.service';
import { Auth } from '../common/auth/auth.decorator';

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
 *
 * NO @RateLimit DECORATOR HERE — AND THAT IS DELIBERATE.
 * This is the one endpoint whose limit is applied inside the SERVICE rather
 * than by the global guard. Only a cache MISS reaches Google and costs money,
 * so only a cache miss should consume budget — and the guard runs before the
 * handler can consult its cache, which would make every cached answer count
 * against the caller. RoutesService calls the limiter itself with the
 * `routes:compute` policy, immediately after the cache lookup.
 *
 * The route is still covered by the guard's `default` policy as an outer
 * backstop, so it is not unprotected: it has two limits, not none.
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
  // The one endpoint that spends real money per call. A journey only exists
  // once a job has been funded and a provider selected, so every legitimate
  // caller is signed in — there was never a reason for this to be reachable
  // anonymously beyond the fact that nothing could check.
  //
  // The IP-keyed spend budget inside RoutesService is unchanged and still the
  // control that bounds Google spend; authentication adds attribution, so an
  // unusual bill can be traced to an account rather than to a carrier NAT
  // shared by half of Nairobi.
  @Auth()
  async compute(
    @Body() dto: ComputeRouteDto,
    @Ip() ip: string,
  ): Promise<RouteResult> {
    // The caller IP is what the per-caller spend budget is keyed on. Render
    // sits behind a proxy, so trust proxy must be enabled for this to be the
    // real client address rather than the edge's.
    return this.routes.computeRoute(
      dto.originLat,
      dto.originLng,
      dto.destLat,
      dto.destLng,
      ip || 'unknown',
    );
  }
}
