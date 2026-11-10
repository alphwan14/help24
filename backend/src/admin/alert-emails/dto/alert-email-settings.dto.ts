import { ArrayMaxSize, IsArray, IsIn, IsString } from 'class-validator';

/** PUT /admin/alert-emails — the signed-in admin's own choice. */
export class AlertEmailSettingsDto {
  @IsIn(['instant', 'daily', 'off'])
  frequency!: 'instant' | 'daily' | 'off';

  @IsArray()
  @ArrayMaxSize(4)
  @IsString({ each: true })
  @IsIn(['financial', 'trust_safety', 'support', 'marketplace'], { each: true })
  categories!: string[];
}
