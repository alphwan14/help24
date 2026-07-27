import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import '../providers/app_provider.dart';
import '../providers/connectivity_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_guard.dart';
import '../widgets/filter_pill.dart';
import '../widgets/job_card.dart';
import '../widgets/loading_empty_offline.dart';
import '../widgets/post_flows.dart';

class JobsScreen extends StatefulWidget {
  const JobsScreen({super.key});

  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen> {
  String _searchQuery = '';
  String _selectedType = 'All';

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text(
              'Job Opportunities',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
          
          // Search Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: TextField(
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
              },
              decoration: InputDecoration(
                hintText: 'Search jobs...',
                prefixIcon: Icon(
                  Iconsax.search_normal,
                  color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                ),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () {
                          setState(() {
                            _searchQuery = '';
                          });
                        },
                      )
                    : null,
              ),
            ),
          ),

          // Type Filter
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: ['All', 'Full-time', 'Part-time', 'Contract', 'Remote'].map((type) {
                  return Padding(
                    padding: const EdgeInsets.only(right: FilterPill.gap),
                    child: FilterPill(
                      label: type,
                      isActive: _selectedType == type,
                      onTap: () => setState(() => _selectedType = type),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Jobs List
          Expanded(
            child: Consumer2<AppProvider, ConnectivityProvider>(
              builder: (context, provider, connectivity, _) {
                var jobs = provider.jobs;

                if (_searchQuery.isNotEmpty) {
                  jobs = jobs.where((job) {
                    return job.title.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                        job.company.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                        job.location.toLowerCase().contains(_searchQuery.toLowerCase());
                  }).toList();
                }

                if (_selectedType != 'All') {
                  if (_selectedType == 'Remote') {
                    jobs = jobs.where((job) => job.location.toLowerCase().contains('remote')).toList();
                  } else {
                    jobs = jobs.where((job) => job.type == _selectedType).toList();
                  }
                }

                if (provider.isLoadingJobs && jobs.isEmpty) {
                  return const FeedSkeletonList();
                }

                if (jobs.isEmpty) {
                  if (connectivity.isOffline) {
                    return OfflineEmptyView(
                      message: 'No internet connection',
                      onRetry: () {
                        connectivity.checkNow();
                        provider.loadJobs();
                      },
                    );
                  }
                  // Distinguish a load failure from a genuinely empty list —
                  // jobsError is set only when THIS tab's fetch failed. It used
                  // to read a slot Discover and the posting flow also wrote, so
                  // a failed post could render here as a jobs failure.
                  if (provider.jobsError != null) {
                    return ErrorRetryView(
                      message: provider.jobsError!,
                      onRetry: () => provider.loadJobs(),
                    );
                  }
                  return EmptyStateView(
                    icon: Iconsax.briefcase,
                    title: 'No jobs available yet',
                    subtitle: 'Check back later for new opportunities. Pull to refresh or try different filters.',
                    actions: [
                      TextButton.icon(
                        onPressed: () => provider.loadJobs(),
                        icon: const Icon(Icons.refresh, size: 20),
                        label: const Text('Refresh'),
                      ),
                    ],
                  );
                }

                return RefreshIndicator(
                  onRefresh: () => provider.loadJobs(),
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: jobs.length,
                    itemBuilder: (context, index) {
                      final job = jobs[index];
                      // A job IS a post — open the canonical detail screen, the
                      // same one Discover and My Posts open. This tab used to
                      // build its own bottom sheet (title, description and an
                      // Apply button the author could press on their own post);
                      // that sheet is gone, and with it the second definition
                      // of what a job detail is.
                      final post = job.toPostModel();
                      return JobCard(
                        job: job,
                        onTap: () => openPostFromFeed(context, post),
                        onApply: () => AuthGuard.requireAuth(
                          context,
                          action: 'apply for this job',
                          onAuthenticated: () => applyToListing(context, post),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
