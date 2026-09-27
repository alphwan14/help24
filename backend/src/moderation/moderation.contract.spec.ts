import 'reflect-metadata';
import { GUARDS_METADATA, MODULE_METADATA, PATH_METADATA } from '@nestjs/common/constants';
import { getMetadataStorage } from 'class-validator';
import { AUTH_SPEC_KEY, AuthSpec } from '../common/auth/auth.decorator';
import { ROLES_KEY } from '../admin/auth/roles.decorator';
import { RESTRICT_KEY } from './restrict.decorator';
import { AppModule } from '../app.module';
import { AuthModule } from '../common/auth/auth.module';
import { ModerationEnforcementModule } from './moderation-enforcement.module';
import { CreateReportDto, ReportEvidenceUploadDto } from './dto/report.dto';

import { FeedController } from '../feed/feed.controller';
import { JobsController } from '../jobs/jobs.controller';
import { MpesaController } from '../mpesa/mpesa.controller';
import { NotificationsController } from '../notifications/notifications.controller';
import { PromotionsController } from '../promotions/promotions.controller';
import { ReviewsController } from '../reviews/reviews.controller';
import { PayoutDestinationsController } from '../payouts/payout-destinations.controller';
import { ProvidersController } from '../providers/providers.controller';
import { DisputesPublicController } from '../admin/disputes/disputes-public.controller';
import { ReportsController } from './reports.controller';
import { ModerationAdminController } from './moderation-admin.controller';

/**
 * The enforcement map, pinned. Adding @Restrict to a route, removing it, or
 * adding a user-facing route that should carry it without doing so is a
 * deliberate edit to this file — never a silent change.
 */
const USER_FACING = [
  FeedController,
  JobsController,
  MpesaController,
  NotificationsController,
  PromotionsController,
  ReviewsController,
  PayoutDestinationsController,
  ProvidersController,
  DisputesPublicController,
  ReportsController,
];

function handlers(controller: Function): Array<{ label: string; target: Function }> {
  const prototype = controller.prototype as Record<string, unknown>;
  return Object.getOwnPropertyNames(prototype)
    .filter((name) => name !== 'constructor' && typeof prototype[name] === 'function')
    .filter((name) => Reflect.getMetadata(PATH_METADATA, prototype[name] as object) !== undefined)
    .map((name) => ({ label: `${controller.name}.${name}`, target: prototype[name] as Function }));
}

const ALL = USER_FACING.flatMap(handlers);
const restricted = Object.fromEntries(
  ALL.map((h) => [h.label, Reflect.getMetadata(RESTRICT_KEY, h.target) as string | undefined]).filter(([, cap]) => cap),
);

describe('moderation contract — which routes a restriction can close', () => {
  it('is exactly this map', () => {
    expect(restricted).toEqual({
      'JobsController.notifyApplication': 'apply',
      'JobsController.selectProvider': 'hire',
      'JobsController.markComplete': 'complete',
      'MpesaController.initiatePayment': 'pay',
      'NotificationsController.chatMessage': 'message',
      'PromotionsController.createCampaign': 'promote',
      'PromotionsController.pay': 'promote',
      'PromotionsController.resume': 'promote',
      'ReviewsController.create': 'review',
      'PayoutDestinationsController.add': 'payout_config',
      'PayoutDestinationsController.requestChallenge': 'payout_config',
      'PayoutDestinationsController.verify': 'payout_config',
      'PayoutDestinationsController.setDefault': 'payout_config',
    });
  });

  it('never closes a route that SETTLES an existing obligation or seeks help', () => {
    // Blocking these would strand an innocent counterparty's money, or leave a
    // sanctioned person no way to contest a decision.
    for (const label of [
      'JobsController.approve',
      'JobsController.archive',
      'JobsController.getLifecycle',
      'JobsController.getReceipt',
      'DisputesPublicController.create',
      'DisputesPublicController.reply',
      'DisputesPublicController.uploadUrl',
      'DisputesPublicController.submitEvidence',
      'PayoutDestinationsController.retire',
      'PromotionsController.pause',
      'PromotionsController.cancel',
      'ReportsController.create',
    ]) {
      expect(ALL.map((h) => h.label)).toContain(label);
      expect(restricted[label]).toBeUndefined();
    }
  });

  it('every restricted route requires a Firebase identity and declares whose it is', () => {
    for (const { label, target } of ALL) {
      if (!restricted[label]) continue;
      const spec = Reflect.getMetadata(AUTH_SPEC_KEY, target) as AuthSpec | undefined;
      expect({ label, scheme: spec?.scheme }).toEqual({ label, scheme: 'firebase' });
      expect({ label, bindings: (spec?.bindings.length ?? 0) > 0 }).toEqual({ label, bindings: true });
    }
  });
});

describe('moderation contract — reporting', () => {
  it('both routes demand a VERIFIED token regardless of the migration mode', () => {
    for (const { label, target } of handlers(ReportsController)) {
      const spec = Reflect.getMetadata(AUTH_SPEC_KEY, target) as AuthSpec;
      expect({ label, critical: spec.critical, scheme: spec.scheme }).toEqual({ label, critical: true, scheme: 'firebase' });
      expect(spec.bindings.map((b) => `${b.source}.${b.field}`)).toEqual(['body.reporter_id']);
    }
  });

  it('the bound field exists on both DTOs (forbidNonWhitelisted would 400 otherwise)', () => {
    for (const dto of [CreateReportDto, ReportEvidenceUploadDto]) {
      const props = getMetadataStorage().getTargetValidationMetadatas(dto, dto.name, true, false).map((m) => m.propertyName);
      expect(props).toContain('reporter_id');
    }
  });
});

describe('moderation contract — the admin console API', () => {
  const routes = handlers(ModerationAdminController);

  it('has the expected surface', () => {
    expect(routes.map((r) => r.label.split('.')[1]).sort()).toEqual([
      'admins', 'audit', 'getReport', 'getUser', 'integrity', 'lift', 'listReports',
      'noteOnReport', 'noteOnUser', 'removeContent', 'resolve', 'restoreContent',
      'restricted', 'sanction', 'summary', 'triage',
    ]);
  });

  it('is admin-scheme, behind AdminAuthGuard, under /admin, with a role on every route', () => {
    expect(Reflect.getMetadata(PATH_METADATA, ModerationAdminController)).toBe('admin/moderation');
    const guards = (Reflect.getMetadata(GUARDS_METADATA, ModerationAdminController) as Function[]).map((g) => g.name);
    expect(guards).toContain('AdminAuthGuard');
    for (const { label, target } of routes) {
      const spec = (Reflect.getMetadata(AUTH_SPEC_KEY, target) ?? Reflect.getMetadata(AUTH_SPEC_KEY, ModerationAdminController)) as AuthSpec;
      expect({ label, scheme: spec.scheme }).toEqual({ label, scheme: 'admin' });
      expect({ label, role: !!Reflect.getMetadata(ROLES_KEY, target) }).toEqual({ label, role: true });
    }
  });

  it('lifting a sanction starts at senior_admin; reading the chain proof too', () => {
    const role = (name: string) => Reflect.getMetadata(ROLES_KEY, routes.find((r) => r.label.endsWith(`.${name}`))!.target);
    expect(role('lift')).toBe('senior_admin');
    expect(role('integrity')).toBe('senior_admin');
  });
});

describe('moderation contract — guard ordering', () => {
  it('ModerationEnforcementModule is registered immediately after AuthModule', () => {
    const imports = Reflect.getMetadata(MODULE_METADATA.IMPORTS, AppModule) as unknown[];
    expect(imports.indexOf(ModerationEnforcementModule)).toBe(imports.indexOf(AuthModule) + 1);
  });
});
