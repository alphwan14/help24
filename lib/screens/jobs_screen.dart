import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/job_card.dart';
import '../widgets/application_modal.dart';

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
                  final isSelected = _selectedType == type;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedType = type;
                        });
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppTheme.primaryAccent
                              : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: isSelected
                                ? AppTheme.primaryAccent
                                : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
                          ),
                        ),
                        child: Text(
                          type,
                          style: TextStyle(
                            color: isSelected
                                ? Colors.white
                                : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Jobs List
          Expanded(
            child: Consumer<AppProvider>(
              builder: (context, provider, _) {
                var jobs = provider.jobs;

                // Filter by search
                if (_searchQuery.isNotEmpty) {
                  jobs = jobs.where((job) {
                    return job.title.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                        job.company.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                        job.location.toLowerCase().contains(_searchQuery.toLowerCase());
                  }).toList();
                }

                // Filter by type
                if (_selectedType != 'All') {
                  if (_selectedType == 'Remote') {
                    jobs = jobs.where((job) => job.location.toLowerCase().contains('remote')).toList();
                  } else {
                    jobs = jobs.where((job) => job.type == _selectedType).toList();
                  }
                }

                if (jobs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Icon(
                            Iconsax.briefcase,
                            size: 36,
                            color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'No jobs found',
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Check back later for new opportunities',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: jobs.length,
                  itemBuilder: (context, index) {
                    final job = jobs[index];
                    return JobCard(
                      job: job,
                      onApply: () => _showApplyModal(context, job),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showApplyModal(BuildContext context, JobModel job) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ApplicationModal(
          title: job.title,
          type: 'job',
          onSubmit: (message, proposedPrice) {
            final provider = context.read<AppProvider>();
            final application = Application(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              applicantName: 'You',
              message: message,
              proposedPrice: proposedPrice,
              timestamp: DateTime.now(),
            );
            provider.addApplicationToJob(job.id, application);
          },
        ),
      ),
    );
  }
}
