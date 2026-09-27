import { Body, Controller, HttpCode, HttpStatus, Post } from '@nestjs/common';
import { AuthCritical } from '../common/auth/auth.decorator';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import { CreateReportDto, ReportEvidenceUploadDto } from './dto/report.dto';
import { ReportEvidenceService } from './report-evidence.service';
import { ReportsService } from './reports.service';

/**
 * Reporting — the user-facing half of Trust & Safety.
 *
 * WHY @AuthCritical AND NOT @Auth
 * -------------------------------
 * A report is an accusation attributed to a person. Under the graduated auth
 * migration an ordinary @Auth route still accepts a token-less caller acting on
 * an ASSERTED id — which here would let anyone file reports in someone else's
 * name, or bury a rival under "their own" complaints. Attribution is the whole
 * value of a report, so these routes require a verified token unconditionally,
 * like the payout routes. The shipped app already attaches one to every backend
 * request (Help24ApiClient).
 *
 * Deliberately NOT @Restrict: a restricted person can still report abuse
 * aimed at them. Volume is bounded by the rate limit here and the daily caps in
 * the database.
 */
@Controller('reports')
export class ReportsController {
  constructor(
    private readonly reports: ReportsService,
    private readonly evidence: ReportEvidenceService,
  ) {}

  @Post()
  @HttpCode(HttpStatus.CREATED)
  @RateLimit('reports:create')
  @AuthCritical('body.reporter_id')
  create(@Body() dto: CreateReportDto) {
    return this.reports.create(dto);
  }

  /** Signed upload URLs for up to three screenshots, under the reporter's own prefix. */
  @Post('evidence/upload-url')
  @HttpCode(HttpStatus.OK)
  @RateLimit('uploads:sign')
  @AuthCritical('body.reporter_id')
  async uploadUrls(@Body() dto: ReportEvidenceUploadDto) {
    const files = await this.evidence.issueUploadUrls(dto.reporter_id ?? '', dto.files);
    return { files };
  }
}
