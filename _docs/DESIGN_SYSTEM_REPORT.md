# Help24 Design System Report

Structured design system extracted from the Help24 Flutter mobile app for reuse (e.g. marketing website) with identical visual identity.

---

## 1. Primary color palette (hex)

| Token        | Hex       | Usage                    |
|-------------|-----------|---------------------------|
| Primary     | `#6366F1` | Primary accent, CTAs, links, selected states |
| Secondary   | `#22D3EE` | Secondary accent, gradients (with primary)   |

---

## 2. Secondary and accent colors

| Token        | Hex       | Usage                          |
|-------------|-----------|---------------------------------|
| Success     | `#10B981` | Success states, positive, "Flexible" urgency |
| Warning     | `#F59E0B` | Warnings, "Soon" urgency, ratings |
| Error       | `#EF4444` | Errors, destructive, "Urgent" urgency |
| Request (type) | `#2196F3` | Request badge (blue)   |
| Offer (type)   | `#4CAF50` | Offer badge (green)    |
| Job (type)     | `#9C27B0` | Job badge (purple)     |
| Difficulty Easy  | `#4CAF50` | Green  |
| Difficulty Medium| `#FF9800` | Orange |
| Difficulty Hard  | `#E53935` | Red    |
| Difficulty Any   | `#6B7280` | Gray   |

---

## 3. Background colors (light / dark surfaces)

### Dark theme

| Token    | Hex       | Usage                    |
|----------|-----------|---------------------------|
| Background | `#0A0A0A` | Scaffold, app background  |
| Surface    | `#141414` | Surfaces, nav bar         |
| Card       | `#1C1C1E` | Cards, inputs, chips     |
| Card hover | `#252528` | Hover (if used)           |
| Border     | `#2C2C30` | Borders, dividers         |

### Light theme

| Token    | Hex       | Usage                    |
|----------|-----------|---------------------------|
| Background | `#F8F9FA` | Scaffold, app background  |
| Surface    | `#FFFFFF` | Surfaces, nav bar, inputs|
| Card       | `#FFFFFF` | Cards                     |
| Border     | `#E5E7EB` | Borders, dividers         |

---

## 4. Text colors

### Dark theme

| Token   | Hex       |
|---------|-----------|
| Primary   | `#F9FAFB` |
| Secondary | `#9CA3AF` |
| Tertiary  | `#6B7280` |

### Light theme

| Token   | Hex       |
|---------|-----------|
| Primary   | `#111827` |
| Secondary | `#6B7280` |
| Tertiary  | `#9CA3AF` |

---

## 5. Button styles

### Primary (elevated)

- **Background:** Primary `#6366F1`
- **Foreground:** White
- **Elevation:** 0 (flat)
- **Padding:** 24px horizontal, 14px vertical
- **Border radius:** 12px
- **Font:** 14px, weight 600 (semibold)

### Secondary (outlined) – dark theme

- **Foreground:** Text primary
- **Border:** 1px surface border
- **Padding:** 24px horizontal, 14px vertical
- **Border radius:** 12px

### Disabled

- Handled by theme (e.g. primary with opacity or muted foreground).

---

## 6. Border radius scale

| Value | Usage                                      |
|-------|--------------------------------------------|
| 2px   | Small indicators (e.g. bottom sheet handle)|
| 6px   | Small tags, compact badges                  |
| 8px   | Badges, type/category chips, small containers |
| 10px  | Media corners (e.g. card image), modals     |
| 12px  | Inputs, buttons, form fields, filters      |
| 14px  | Avatars (rounded rect), nav item            |
| 16px  | Cards, main containers, bottom nav         |
| 20px  | Chips, pill badges, urgency/difficulty      |
| 24px  | Bottom sheets (top corners), modals         |
| 28px   | Auth modal top corners                      |

---

## 7. Shadows and elevation

- **Elevation:** 0 used for app bar, cards, buttons (flat look).
- **Card shadow (dark):** `color: black 20%`, `blurRadius: 8`, `offset: (0, 2)`.
- **Card shadow (light):** `color: black 6%`, `blurRadius: 8`, `offset: (0, 2)`.
- **Bottom nav shadow:** `color: black 8%`, `blurRadius: 16`, `offset: (0, -4)`.

---

## 8. Font family

- **Primary:** **Poppins** (via Google Fonts).
- Use the same family for headings and body for the marketing site.

---

## 9. Font weights

| Weight | Value   | Usage              |
|--------|---------|--------------------|
| Regular  | 400   | Body text           |
| Medium   | 500   | Labels, emphasis   |
| Semibold | 600  | Titles, buttons     |
| Bold     | 700   | Display (H1)        |

---

## 10. Heading sizes (typography scale)

| Style         | Size | Weight | Letter spacing | Usage    |
|---------------|------|--------|----------------|----------|
| displayLarge  | 32px | 700    | -0.5           | H1       |
| displayMedium | 28px | 600    | -0.5           | H2       |
| headlineLarge | 24px | 600    | —              | H3       |
| headlineMedium| 20px | 600    | —              | H4 / App bar |
| headlineSmall | 18px | 600    | —              | H5       |
| titleLarge    | 16px | 600    | —              | Section titles |
| titleMedium   | 14px | 500    | —              | Cards, list titles |
| titleSmall    | 12px | 500    | —              | Overlines, small labels |

---

## 11. Body and label text

| Style      | Size | Weight | Usage           |
|------------|------|--------|------------------|
| bodyLarge  | 16px | 400    | Lead body        |
| bodyMedium | 14px | 400    | Default body     |
| bodySmall  | 12px | 400    | Captions, hints  |
| labelLarge | 14px | 500    | Buttons, nav     |
| labelMedium| 12px | 500    | Small labels     |
| labelSmall | 10px | 500    | Tiny labels      |

---

## 12. Spacing system

### Margins / padding scale

| Token   | Value  | Usage                          |
|---------|--------|---------------------------------|
| 4px     | 4      | Tight (e.g. icon–text)          |
| 6px     | 6      | Badge internal, spacing        |
| 8px     | 8      | Small gap, tag spacing         |
| 10px    | 10     | Badge padding                  |
| 12px    | 12     | Section gaps, vertical padding |
| 14px    | 14     | Input vertical padding         |
| 16px    | 16     | Card padding, horizontal input |
| 20px    | 20     | Screen horizontal, filter pad  |
| 24px    | 24     | Button horizontal, sections    |
| 32px    | 32     | Large vertical spacing         |

### Card-specific (PostCard / JobCard)

- **Padding:** 16px (all sides of content; bottom row 16px horizontal, 12px vertical).
- **Gap between elements:** 12px.
- **Margin below card:** 16px.

---

## 13. Card design structure

- **Background:** Surface/card color (dark `#1C1C1E`, light `#FFFFFF`).
- **Border:** 1px border (dark `#2C2C30`, light `#E5E7EB`).
- **Border radius:** 16px.
- **Shadow:** As in §7 (light/dark).
- **Internal padding:** 16px; bottom row 16px horizontal, 12px vertical.
- **Content order:** Badges row → Title → Tags (difficulty/urgency) → User row (avatar, name, rating, location) → Description → Optional media (72px height) → Bottom row (price, CTA).
- **Avatar size:** 36px.

---

## 14. Badge styles

### Type badge (Request / Offer / Job)

- **Padding:** 8px horizontal, 4px vertical.
- **Border radius:** 8px.
- **Background:** Type color at 15% opacity.
- **Border:** 1px, type color at 50% opacity.
- **Font:** 11px, weight 600, color = type color.

### Category badge

- **Padding:** 10px horizontal, 5px vertical.
- **Border radius:** 8px.
- **Background:** Primary at 10% (light) / 20% (dark).
- **Content:** Icon 14px + 6px gap + label.
- **Font:** 12px, weight 500, primary color.

### Small tag (difficulty / urgency)

- **Padding:** 8px horizontal, 4px vertical.
- **Border radius:** 6px (small tag) or 20px (pill).
- **Background:** Semantic color at 12% opacity.
- **Font:** 11px, weight 600, semantic color.

### Chip (theme)

- **Border radius:** 20px (pill).
- **Border:** 1px surface border.
- **Background:** Card/surface; selected: primary 10–20% opacity.

---

## 15. Input field styling

- **Filled:** Yes.
- **Fill color:** Card (dark) / Surface (light).
- **Border radius:** 12px.
- **Default border:** 1px surface border.
- **Focused border:** 1.5px primary.
- **Content padding:** 16px horizontal, 14px vertical.
- **Hint:** Tertiary text color.

---

## 16. Overall UI style classification

- **Style:** **Modern, minimal, flat**.
- **Framework:** Material 3 with custom tokens.
- **Characteristics:**
  - Flat (elevation 0) for app bar, cards, buttons.
  - Rounded corners (8–24px) and consistent 12px for inputs/buttons.
  - Clear light/dark themes with dark default (premium deep black).
  - Poppins typography, clear hierarchy (display → body → label).
  - Semantic colors for status (success, warning, error) and type (request/offer/job).
  - Subtle shadows on cards and bottom nav only.
  - Spacing scale (4–32px) and 16px card padding for consistency.
  - No neumorphism, no heavy gradients (except optional accent gradient).
  - Icons: Iconsax used in app (can be mirrored or replaced on web).

---

## Quick reference – CSS-ready values

```css
/* Colors */
--primary: #6366F1;
--secondary: #22D3EE;
--success: #10B981;
--warning: #F59E0B;
--error: #EF4444;
--dark-bg: #0A0A0A;
--dark-surface: #141414;
--dark-card: #1C1C1E;
--dark-border: #2C2C30;
--light-bg: #F8F9FA;
--light-surface: #FFFFFF;
--light-border: #E5E7EB;
--dark-text: #F9FAFB;
--dark-text-muted: #9CA3AF;
--light-text: #111827;
--light-text-muted: #6B7280;

/* Radius */
--radius-sm: 6px;
--radius-md: 12px;
--radius-lg: 16px;
--radius-pill: 20px;

/* Spacing */
--space-1: 4px;
--space-2: 8px;
--space-3: 12px;
--space-4: 16px;
--space-5: 20px;
--space-6: 24px;

/* Typography */
--font-family: 'Poppins', sans-serif;
--text-display: 32px / 700;
--text-h2: 28px / 600;
--text-h3: 24px / 600;
--text-body: 14px / 400;
--text-small: 12px / 400;
```

---

*Generated from Help24 Flutter app (theme, post_card, job_card, marketplace_card_components, custom_bottom_nav, filter_bottom_sheet, application_modal).*
