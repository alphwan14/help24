# Help24

A modern multi-service marketplace mobile app built with Flutter. This is a UI/UX-focused project featuring a premium dark theme design.

## Features

- **Discover Screen**: Browse service requests and offers with real-time search and filtering
- **Jobs Screen**: View and apply for job opportunities
- **Post Screen**: Multi-step posting flow for requests, offers, and jobs
- **Messages Screen**: Modern chat interface with conversation list
- **Profile Screen**: User settings with dark/light theme toggle

## Design

- Premium dark theme (default) with light mode option
- Modern UI with Inter font family
- Smooth animations using flutter_animate
- Custom bottom navigation with floating action button
- Consistent spacing, rounded corners, and soft shadows

## Getting Started

### Prerequisites

- Flutter SDK (3.0.0 or higher)
- Android Studio / VS Code
- Android Emulator or iOS Simulator

### Installation

1. Navigate to the project directory:
```bash
cd help24
```

2. Get dependencies:
```bash
flutter pub get
```

3. Run the app:
```bash
flutter run
```

## Project Structure

```
lib/
├── main.dart              # App entry point
├── models/
│   └── post_model.dart    # Data models
├── providers/
│   └── app_provider.dart  # State management
├── screens/
│   ├── discover_screen.dart
│   ├── jobs_screen.dart
│   ├── post_screen.dart
│   ├── messages_screen.dart
│   ├── profile_screen.dart
│   └── home_screen.dart
├── theme/
│   └── app_theme.dart     # Dark/Light themes
└── widgets/
    ├── post_card.dart
    ├── job_card.dart
    ├── filter_bottom_sheet.dart
    └── custom_bottom_nav.dart
```

## Dependencies

- `provider` - State management
- `google_fonts` - Custom typography (Inter)
- `flutter_animate` - Smooth animations
- `iconsax` - Modern icon pack

## Screenshots

The app features:
- Premium dark theme with deep dark backgrounds
- Urgency badges (Urgent/Soon/Flexible) with colored indicators
- Real-time search and filtering
- Category-based filtering with icons
- Modern chat bubbles
- Profile settings with theme toggle

## License

This project is for demonstration purposes.
