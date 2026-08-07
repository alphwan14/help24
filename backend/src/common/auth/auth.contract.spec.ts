import 'reflect-metadata';
import { ROUTE_ARGS_METADATA, PATH_METADATA } from '@nestjs/common/constants';
import { RouteParamtypes } from '@nestjs/common/enums/route-paramtypes.enum';
import { getMetadataStorage } from 'class-validator';
import { AUTH_SPEC_KEY, AuthSpec } from './auth.decorator';
import { IdentityBinding } from './identity-binding';

// Every controller in the application. Imported directly rather than booted, so
// this suite needs no environment, no Supabase and no Firebase.
import { FeedController } from '../../feed/feed.controller';
import { FeedSettingsAdminController } from '../../feed/feed-settings-admin.controller';
import { JobsController } from '../../jobs/jobs.controller';
import { MpesaController } from '../../mpesa/mpesa.controller';
import { NotificationsController } from '../../notifications/notifications.controller';
import { PromotionsController } from '../../promotions/promotions.controller';
import { PromotionsAdminController } from '../../promotions/promotions-admin.controller';
import { ReviewsController } from '../../reviews/reviews.controller';
import { ReputationController } from '../../reputation/reputation.controller';
import { ProvidersController } from '../../providers/providers.controller';
import { RoutesController } from '../../routes/routes.controller';
import { HealthController, RootController } from '../../health/health.controller';
import { DevController } from '../../dev/dev.controller';
import { EventsAdminController } from '../../events/events-admin.controller';
import { EventsHealthController } from '../../events/events-health.controller';
import { AdminController } from '../../admin/admin.controller';
import { AdminUsersController } from '../../admin/admin-users.controller';
import { AdminInvitesPublicController } from '../../admin/admin-invites-public.controller';
import { DisputesController } from '../../admin/disputes/disputes.controller';
import { DisputesPublicController } from '../../admin/disputes/disputes-public.controller';
import { AppConfigController } from '../../app-config/app-config.controller';
import { AppConfigAdminController } from '../../app-config/app-config-admin.controller';

const CONTROLLERS = [
  FeedController,
  FeedSettingsAdminController,
  JobsController,
  MpesaController,
  NotificationsController,
  PromotionsController,
  PromotionsAdminController,
  ReviewsController,
  ReputationController,
  ProvidersController,
  RoutesController,
  HealthController,
  RootController,
  DevController,
  EventsAdminController,
  EventsHealthController,
  AdminController,
  AdminUsersController,
  AdminInvitesPublicController,
  DisputesController,
  DisputesPublicController,
  AppConfigController,
  AppConfigAdminController,
] as const;

interface Handler {
  readonly controller: string;
  readonly handler: string;
  readonly target: Function;
  readonly spec?: AuthSpec;
  /** DTO classes bound to a WHOLE @Body()/@Query() — the whitelisted ones. */
  readonly wholeBagDtos: { readonly source: 'body' | 'query'; readonly dto: Function }[];
}

function handlersOf(controller: Function): Handler[] {
  const prototype = controller.prototype as object;
  const classSpec = Reflect.getMetadata(AUTH_SPEC_KEY, controller) as AuthSpec | undefined;

  return Object.getOwnPropertyNames(prototype)
    .filter((name) => name !== 'constructor')
    .filter((name) => typeof (prototype as Record<string, unknown>)[name] === 'function')
    .filter((name) => Reflect.getMetadata(PATH_METADATA, (prototype as Record<string, Function>)[name]) !== undefined)
    .map((name) => {
      const target = (prototype as Record<string, Function>)[name];
      const paramTypes = (Reflect.getMetadata('design:paramtypes', prototype, name) ?? []) as Function[];
      const args = (Reflect.getMetadata(ROUTE_ARGS_METADATA, controller, name) ?? {}) as Record<
        string,
        { index: number; data?: unknown }
      >;

      const wholeBagDtos: Handler['wholeBagDtos'] = [];
      for (const [key, arg] of Object.entries(args)) {
        const paramType = Number(key.split(':')[0]);
        const source =
          paramType === RouteParamtypes.BODY ? 'body' : paramType === RouteParamtypes.QUERY ? 'query' : null;
        // `data` set means `@Body('field')` — a single extracted value, which
        // ValidationPipe does NOT whitelist. Only whole-object binding matters.
        if (!source || arg.data !== undefined) continue;
        const dto = paramTypes[arg.index];
        if (dto && dto !== Object && dto !== String) wholeBagDtos.push({ source, dto });
      }

      return {
        controller: controller.name,
        handler: name,
        target,
        spec: (Reflect.getMetadata(AUTH_SPEC_KEY, target) as AuthSpec | undefined) ?? classSpec,
        wholeBagDtos,
      };
    });
}

const ALL_HANDLERS = CONTROLLERS.flatMap(handlersOf);

/** Property names class-validator knows about for a DTO, including inherited. */
function declaredProperties(dto: Function): Set<string> {
  const properties = new Set<string>();
  for (const meta of getMetadataStorage().getTargetValidationMetadatas(dto, dto.name, true, false)) {
    if (meta.propertyName) properties.add(meta.propertyName);
  }
  return properties;
}

describe('auth contract — every route is classified', () => {
  it('has at least one route per controller (the harness itself works)', () => {
    expect(ALL_HANDLERS.length).toBeGreaterThan(50);
  });

  it('declares an auth scheme on every route', () => {
    // Mirrors RouteAuditService's first rule, but at build time: a route that
    // nobody classified is one nobody reasoned about.
    const undeclared = ALL_HANDLERS.filter((h) => !h.spec).map((h) => `${h.controller}.${h.handler}`);
    expect(undeclared).toEqual([]);
  });

  it('gives every public route a stated reason', () => {
    const unexplained = ALL_HANDLERS.filter(
      (h) => h.spec?.scheme === 'public' && !h.spec.reason?.trim(),
    ).map((h) => `${h.controller}.${h.handler}`);
    expect(unexplained).toEqual([]);
  });
});

describe('auth contract — bindings match their DTOs', () => {
  /**
   * THE CONSTRAINT THIS ENFORCES, AND WHY IT IS NOT OBVIOUS.
   *
   * The global ValidationPipe runs with `forbidNonWhitelisted: true`. Guards run
   * BEFORE pipes — which is exactly what lets the guard's injected identity be
   * validated and reach the handler — but it also means an injected field that
   * the DTO does not declare is rejected as an unknown property. The endpoint
   * would answer 400 for every authenticated caller, and ONLY for authenticated
   * callers, so it would pass every anonymous smoke test and fail the moment
   * enforcement was switched on.
   *
   * That is a failure mode with no runtime signal until it is too late, so it is
   * checked here instead.
   */
  const bindingsToCheck: Array<{ handler: Handler; binding: IdentityBinding; dto: Function }> = [];

  for (const handler of ALL_HANDLERS) {
    for (const binding of handler.spec?.bindings ?? []) {
      const bag = handler.wholeBagDtos.find((b) => b.source === binding.source);
      if (bag) bindingsToCheck.push({ handler, binding, dto: bag.dto });
    }
  }

  it('found bindings that land in a whitelisted DTO', () => {
    // If this ever drops to zero the suite below is vacuous.
    expect(bindingsToCheck.length).toBeGreaterThan(10);
  });

  it.each(bindingsToCheck.map((b) => [`${b.handler.controller}.${b.handler.handler}`, b] as const))(
    '%s binds a field its DTO declares',
    (_label, { binding, dto }) => {
      expect(declaredProperties(dto)).toContain(binding.field);
    },
  );
});

describe('auth contract — the select-provider trap', () => {
  it('binds the caller and never the provider being selected', () => {
    // `SelectProviderDto` carries BOTH `client_user_id` (the caller) and
    // `provider_id` (the person being assigned). Binding the second would let
    // anyone assign themselves to any open job — an authorization hole created
    // by the authorization layer. This is the concrete reason bindings are
    // declared per route rather than inferred from a `/user_id$/` convention.
    const handler = ALL_HANDLERS.find((h) => h.handler === 'selectProvider');
    expect(handler).toBeDefined();

    const fields = (handler!.spec?.bindings ?? []).map((b) => `${b.source}.${b.field}`);
    expect(fields).toEqual(['body.client_user_id']);
    expect(fields).not.toContain('body.provider_id');
  });
});

describe('auth contract — money and third-party-impact routes are protected', () => {
  // A named list, because these are the routes where an authorization mistake
  // costs a user money or puts a notification on a stranger's phone. If any of
  // them is ever relaxed to `public`, that should take a deliberate edit here.
  const MUST_REQUIRE_IDENTITY: Array<[string, string]> = [
    ['JobsController', 'approve'],
    ['JobsController', 'markComplete'],
    ['JobsController', 'selectProvider'],
    ['JobsController', 'notifyApplication'],
    ['JobsController', 'archive'],
    ['MpesaController', 'initiatePayment'],
    ['NotificationsController', 'chatMessage'],
    ['ReviewsController', 'create'],
    ['DisputesPublicController', 'create'],
    ['DisputesPublicController', 'uploadUrl'],
    ['PromotionsController', 'pay'],
    ['PromotionsController', 'createCampaign'],
    ['FeedController', 'setAvailability'],
    ['RoutesController', 'compute'],
  ];

  it.each(MUST_REQUIRE_IDENTITY)('%s.%s requires a verified identity', (controller, handler) => {
    const found = ALL_HANDLERS.find((h) => h.controller === controller && h.handler === handler);
    expect(found).toBeDefined();
    expect(found!.spec?.scheme).toBe('firebase');
  });

  it('escrow release is admin-only, not merely authenticated', () => {
    // The body carries only `post_id`, so there is no caller to bind — the only
    // safe classification is the admin credential.
    const found = ALL_HANDLERS.find((h) => h.handler === 'releasePayout');
    expect(found?.spec?.scheme).toBe('admin');
  });
});

describe('auth contract — anonymous browsing still works', () => {
  const MUST_STAY_PUBLIC: Array<[string, string]> = [
    ['FeedController', 'getFeed'],
    ['PromotionsController', 'listPackages'],
    ['PromotionsController', 'getSlots'],
    ['ReputationController', 'getReputation'],
    ['ReputationController', 'getReputationMany'],
    ['ReputationController', 'listProviderReviews'],
    ['HealthController', 'liveness'],
    ['RootController', 'root'],
    ['MpesaController', 'stkCallback'],
    ['MpesaController', 'b2cCallback'],
    ['MpesaController', 'b2cStatusResult'],
  ];

  it.each(MUST_STAY_PUBLIC)('%s.%s stays reachable without an account', (controller, handler) => {
    const found = ALL_HANDLERS.find((h) => h.controller === controller && h.handler === handler);
    expect(found).toBeDefined();
    expect(found!.spec?.scheme).toBe('public');
  });

  it('personalises the feed only for the caller it can prove', () => {
    const feed = ALL_HANDLERS.find((h) => h.handler === 'getFeed');
    const bindings = feed?.spec?.bindings ?? [];
    expect(bindings).toHaveLength(1);
    expect(bindings[0]).toMatchObject({ source: 'query', field: 'user_id', mode: 'optional' });
  });
});
