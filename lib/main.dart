import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:path_provider/path_provider.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'firebase_options.dart';

const kLogoPath = 'assets/logo.png';
const double kWelcomeLogoHeight = 200;
const double kAppBarLogoHeight = 60;

/// current app-side role (not auth): 'innovator' or 'company'
String currentUserRole = 'innovator';

/// ---------- FIREBASE INITIALIZATION ----------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Object? startupError;
  StackTrace? startupStack;

  try {
    // Avoid calling initializeApp twice (fixes [core/duplicate-app])
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } else {
      debugPrint(
          'Firebase already initialized (${Firebase.apps.first.name}), skipping initializeApp');
    }

    // Optional: sign in anonymously so rules that require auth work
    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuth.instance.signInAnonymously();
      debugPrint(
          '✅ Anonymous sign-in OK. uid=${FirebaseAuth.instance.currentUser?.uid}');
    }
  } on FirebaseException catch (e, st) {
    if (e.code == 'duplicate-app') {
      debugPrint(
          '⚠️ Firebase default app already exists, continuing anyway (duplicate-app).');
    } else {
      debugPrint('❌ Firebase startup error: $e');
      startupError = e;
      startupStack = st;
    }
  } catch (e, st) {
    debugPrint('❌ Non-Firebase startup error: $e');
    startupError = e;
    startupStack = st;
  }

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exceptionAsString()}');
    if (details.stack != null) debugPrint(details.stack.toString());
  };

  runZonedGuarded(
        () {
      if (startupError == null) {
        runApp(const ProjectSyncApp());
      } else {
        runApp(StartupErrorScreen(
          error: startupError!,
          stack: startupStack ?? StackTrace.empty,
        ));
      }
    },
        (error, stack) {
      debugPrint('Uncaught zone error: $error\n$stack');
    },
  );
}

/// Minimal screen to surface startup errors instead of a blank white screen.
class StartupErrorScreen extends StatelessWidget {
  final Object error;
  final StackTrace stack;
  const StartupErrorScreen(
      {super.key, required this.error, required this.stack});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ListView(
              children: [
                const SizedBox(height: 24),
                const Text('Startup error',
                    style:
                    TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text('$error', style: const TextStyle(color: Colors.red)),
                const SizedBox(height: 12),
                Text('$stack', style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ---------- DATA MODELS ----------

class Attachment {
  final String name;
  final String? path; // local file path
  final int? size;
  final String? extension;
  final String? assetPath;
  final Uint8List? bytes;

  /// Firebase Storage path, e.g. "projects/uid/123_logo.png"
  final String? storagePath;

  const Attachment({
    required this.name,
    required this.path,
    required this.size,
    required this.extension,
    this.assetPath,
    this.bytes,
    this.storagePath,
  });

  Map<String, dynamic> toMap() => {
    'name': name,
    'path': path,
    'size': size,
    'extension': extension,
    'assetPath': assetPath,
    'storagePath': storagePath,
  };

  factory Attachment.fromMap(Map<String, dynamic> m) => Attachment(
    name: (m['name'] ?? '') as String,
    path: m['path'] as String?,
    size: (m['size'] as num?)?.toInt(),
    extension: m['extension'] as String?,
    assetPath: m['assetPath'] as String?,
    bytes: null, // we don’t load bytes from Firestore
    storagePath: m['storagePath'] as String?,
  );
}

class Project {
  final String id;
  final String title;
  final String desc;
  final String author; // uid
  final String authorName; // human-readable name
  final DateTime createdAt;
  final List<Attachment> files;
  final bool adopted;
  final String field; // category/field

  Project({
    required this.id,
    required this.title,
    required this.desc,
    required this.author,
    required this.createdAt,
    required this.files,
    this.adopted = false,
    this.authorName = 'Innovator',
    this.field = '',
  });

  Map<String, dynamic> toMap() => {
    'title': title,
    'desc': desc,
    'author': author,
    'authorName': authorName,
    'createdAt': Timestamp.fromDate(createdAt),
    'files': files.map((e) => e.toMap()).toList(),
    'adopted': adopted,
    'field': field,
  };

  factory Project.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    final adopted = d['adopted'];
    return Project(
      id: doc.id,
      title: d['title'] as String? ?? '',
      desc: d['desc'] as String? ?? '',
      author: d['author'] as String? ?? 'innovator',
      authorName: d['authorName'] as String? ?? 'Innovator',
      createdAt: (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      files: ((d['files'] as List?) ?? [])
          .whereType<Map<String, dynamic>>()
          .map(Attachment.fromMap)
          .toList(),
      adopted: adopted is bool ? adopted : false,
      field: d['field'] as String? ?? '',
    );
  }
}

class ChatMessage {
  final String id;
  final String text;
  final String senderId;
  final String role; // 'innovator' or 'company'
  final DateTime createdAt;
  final List<Attachment> attachments;

  ChatMessage({
    required this.id,
    required this.text,
    required this.senderId,
    required this.role,
    required this.createdAt,
    required this.attachments,
  });

  Map<String, dynamic> toMap() => {
    'text': text,
    'senderId': senderId,
    'role': role,
    'createdAt': Timestamp.fromDate(createdAt),
    'attachments': attachments.map((e) => e.toMap()).toList(),
  };

  factory ChatMessage.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    final ts = d['createdAt'];
    DateTime created;
    if (ts is Timestamp) {
      created = ts.toDate();
    } else if (ts is DateTime) {
      created = ts;
    } else {
      created = DateTime.now();
    }

    final rawList = (d['attachments'] as List?) ?? [];
    final atts = rawList
        .whereType<Map<String, dynamic>>()
        .map(Attachment.fromMap)
        .toList();

    return ChatMessage(
      id: doc.id,
      text: d['text'] as String? ?? '',
      senderId: d['senderId'] as String? ?? '',
      role: d['role'] as String? ?? 'unknown',
      createdAt: created,
      attachments: atts,
    );
  }
}

/// ---------- APP STATE / THEME / LOCALIZATION ----------

class AppState extends InheritedWidget {
  final ValueNotifier<Locale> locale;
  const AppState({super.key, required this.locale, required super.child});
  static AppState of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<AppState>()!;
  @override
  bool updateShouldNotify(AppState oldWidget) => locale != oldWidget.locale;
}

class ThemeController extends ChangeNotifier {
  Color _seed = const Color(0xFF4154AF);
  Color get seed => _seed;

  Future<void> deriveFromLogo() async {
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        const AssetImage(kLogoPath),
        maximumColorCount: 16,
      );
      final c = palette.vibrantColor?.color ??
          palette.dominantColor?.color ??
          palette.lightVibrantColor?.color ??
          palette.darkVibrantColor?.color;
      if (c != null) {
        _seed = c;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Palette derive error: $e');
    }
  }
}

class ProjectSyncApp extends StatefulWidget {
  const ProjectSyncApp({super.key});
  @override
  State<ProjectSyncApp> createState() => _ProjectSyncAppState();
}

class _ProjectSyncAppState extends State<ProjectSyncApp> {
  final _locale = ValueNotifier(const Locale('en'));
  final _theme = ThemeController();

  @override
  void initState() {
    super.initState();
    _theme.deriveFromLogo();
  }

  @override
  Widget build(BuildContext context) {
    return AppState(
      locale: _locale,
      child: AnimatedBuilder(
        animation: _theme,
        builder: (_, __) {
          final scheme = ColorScheme.fromSeed(seedColor: _theme.seed);
          final theme = ThemeData(useMaterial3: true, colorScheme: scheme);
          return ValueListenableBuilder<Locale>(
            valueListenable: _locale,
            builder: (_, loc, __) => MaterialApp(
              debugShowCheckedModeBanner: false,
              title: 'Project Sync',
              locale: loc,
              supportedLocales: const [Locale('en'), Locale('ar')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              theme: theme,
              home: const RoleChooserPage(),
            ),
          );
        },
      ),
    );
  }
}

class T {
  static final _s = <String, Map<String, String>>{
    'title': {'en': 'Welcome', 'ar': 'أهلًا'},
    'subtitle': {'en': 'Who are you?', 'ar': 'من أنت؟'},
    'company': {'en': 'Company', 'ar': 'شركة'},
    'innovator': {'en': 'Innovator', 'ar': 'مبتكر'},
    'chooseLang': {'en': 'Language', 'ar': 'اللغة'},
    'english': {'en': 'English', 'ar': 'الإنجليزية'},
    'arabic': {'en': 'Arabic', 'ar': 'العربية'},
    'companyHome': {'en': 'Company', 'ar': 'الشركة'},
    'innovatorHome': {'en': 'Innovator', 'ar': 'المبتكر'},
    'feed': {'en': 'Feed', 'ar': 'الخلاصة'},
    'search': {'en': 'Search', 'ar': 'بحث'},
    'chat': {'en': 'Chat', 'ar': 'الدردشة'},
    'submit': {'en': 'Submit', 'ar': 'إرسال'},
    'submitProject': {'en': 'Submit Project', 'ar': 'إرسال مشروع'},
    'titleRequired': {'en': 'Title is required', 'ar': 'العنوان مطلوب'},
    'descRequired': {'en': 'Description is required', 'ar': 'الوصف مطلوب'},
    'send': {'en': 'Send', 'ar': 'إرسال'},
    'noItems': {'en': 'No projects yet', 'ar': 'لا توجد مشاريع بعد'},
    'byInnovator': {'en': 'by Innovator', 'ar': 'بواسطة مبتكر'},
    'attachments': {'en': 'Attachments', 'ar': 'مرفقات'},
    'open': {'en': 'Open', 'ar': 'فتح'},
    'delete': {'en': 'Delete', 'ar': 'حذف'},
    'confirmDeleteProject': {
      'en': 'Delete this project?',
      'ar': 'هل تريد حذف هذا المشروع؟'
    },
    'confirm': {'en': 'Confirm', 'ar': 'تأكيد'},
    'cancel': {'en': 'Cancel', 'ar': 'إلغاء'},

    // Adoption-related strings
    'adopted': {
      'en': 'Adopted',
      'ar': 'تم اعتماد الفكرة',
    },
    'notAdopted': {
      'en': 'Not adopted yet',
      'ar': 'لم تُعتمد بعد',
    },
    'markAdopted': {
      'en': 'Mark as adopted',
      'ar': 'اعتماد الفكرة',
    },
    'markUnadopted': {
      'en': 'Mark as not adopted',
      'ar': 'إلغاء الاعتماد',
    },
  };

  static String of(BuildContext c, String k) {
    final lang = AppState.of(c).locale.value.languageCode;
    final t = _s[k];
    if (t == null) return k;
    return t[lang] ?? t['en']!;
  }
}

/// ---------- ROLE SELECTION ---------
class RoleChooserPage extends StatelessWidget {
  const RoleChooserPage({super.key});
  @override
  Widget build(BuildContext context) {
    final isAr = AppState.of(context).locale.value.languageCode == 'ar';
    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(T.of(context, 'title')),
          actions: const [_LanguageMenu()],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Image.asset(
                    kLogoPath,
                    height: kWelcomeLogoHeight,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                    const Icon(Icons.apartment, size: kWelcomeLogoHeight),
                  ),
                ),
                Text(
                  T.of(context, 'subtitle'),
                  style: Theme.of(context).textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                _RoleButton(
                  label: T.of(context, 'company'),
                  icon: Icons.apartment,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const CompanyShell()),
                  ),
                ),
                const SizedBox(height: 16),
                _RoleButton(
                  label: T.of(context, 'innovator'),
                  icon: Icons.lightbulb,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const InnovatorShell()),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _RoleButton({
    required this.label,
    required this.icon,
    required this.onTap,
    super.key,
  });
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        icon: Icon(icon),
        label: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Text(label, style: const TextStyle(fontSize: 18)),
        ),
        onPressed: onTap,
      ),
    );
  }
}

class _LanguageMenu extends StatelessWidget {
  const _LanguageMenu({super.key});
  @override
  Widget build(BuildContext context) {
    final n = AppState.of(context).locale;
    final isAr = n.value.languageCode == 'ar';
    return PopupMenuButton<String>(
      tooltip: T.of(context, 'chooseLang'),
      icon: const Icon(Icons.language),
      onSelected: (v) => n.value = Locale(v),
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          checked: !isAr,
          value: 'en',
          child: Text(T.of(context, 'english')),
        ),
        CheckedPopupMenuItem(
          checked: isAr,
          value: 'ar',
          child: Text(T.of(context, 'arabic')),
        ),
      ],
    );
  }
}

/// ---------- SHELLS ----------
class InnovatorShell extends StatefulWidget {
  const InnovatorShell({super.key});
  @override
  State<InnovatorShell> createState() => _InnovatorShellState();
}

class _InnovatorShellState extends State<InnovatorShell> {
  int _idx = 0;

  @override
  void initState() {
    super.initState();
    currentUserRole = 'innovator';
  }

  @override
  Widget build(BuildContext context) {
    final isAr = AppState.of(context).locale.value.languageCode == 'ar';

    final pages = <Widget>[
      const FeedPage(showChat: false),
      const _SearchPage(),
      const ChatThreadsPage(),
      SubmitProjectPage(onSubmitted: () => setState(() => _idx = 0)),
    ];

    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: true,
          toolbarHeight: 64,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                kLogoPath,
                height: kAppBarLogoHeight,
                errorBuilder: (_, __, ___) =>
                const Icon(Icons.apartment, size: 32),
              ),
              const SizedBox(width: 10),
              Text(T.of(context, 'innovatorHome')),
            ],
          ),
          actions: const [_LanguageMenu()],
        ),
        body: pages[_idx],
        bottomNavigationBar:
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream:
          FirebaseFirestore.instance.collection('threads').snapshots(),
          builder: (context, snap) {
            int totalUnread = 0;
            if (snap.hasData) {
              for (final doc in snap.data!.docs) {
                final data = doc.data();
                final u = (data['innovatorUnread'] as num?)?.toInt() ?? 0;
                totalUnread += u;
              }
            }
            final chatLabel = totalUnread > 0
                ? '${T.of(context, 'chat')} ($totalUnread)'
                : T.of(context, 'chat');

            return NavigationBar(
              selectedIndex: _idx,
              onDestinationSelected: (i) => setState(() => _idx = i),
              destinations: [
                NavigationDestination(
                  icon: const Icon(Icons.home_outlined),
                  label: T.of(context, 'feed'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.search),
                  label: T.of(context, 'search'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: chatLabel,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.add_circle_outline),
                  label: T.of(context, 'submit'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class CompanyShell extends StatefulWidget {
  const CompanyShell({super.key});
  @override
  State<CompanyShell> createState() => _CompanyShellState();
}

class _CompanyShellState extends State<CompanyShell> {
  int _idx = 0;

  @override
  void initState() {
    super.initState();
    currentUserRole = 'company';
  }

  @override
  Widget build(BuildContext context) {
    final isAr = AppState.of(context).locale.value.languageCode == 'ar';
    final pages = <Widget>[
      const FeedPage(showChat: true),
      const _SearchPage(),
      const ChatThreadsPage(),
    ];
    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: true,
          toolbarHeight: 64,
          title: Row(mainAxisSize: MainAxisSize.min, children: [
            Image.asset(
              kLogoPath,
              height: kAppBarLogoHeight,
              errorBuilder: (_, __, ___) =>
              const Icon(Icons.apartment, size: 32),
            ),
            const SizedBox(width: 10),
            Text(T.of(context, 'companyHome')),
          ]),
          actions: const [_LanguageMenu()],
        ),
        body: pages[_idx],
        bottomNavigationBar:
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream:
          FirebaseFirestore.instance.collection('threads').snapshots(),
          builder: (context, snap) {
            int totalUnread = 0;
            if (snap.hasData) {
              for (final doc in snap.data!.docs) {
                final data = doc.data();
                final u = (data['companyUnread'] as num?)?.toInt() ?? 0;
                totalUnread += u;
              }
            }
            final chatLabel = totalUnread > 0
                ? '${T.of(context, 'chat')} ($totalUnread)'
                : T.of(context, 'chat');

            return NavigationBar(
              selectedIndex: _idx,
              onDestinationSelected: (i) => setState(() => _idx = i),
              destinations: [
                NavigationDestination(
                    icon: const Icon(Icons.home_outlined),
                    label: T.of(context, 'feed')),
                NavigationDestination(
                    icon: const Icon(Icons.search),
                    label: T.of(context, 'search')),
                NavigationDestination(
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: chatLabel),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// ---------- FEED ----------
class FeedPage extends StatelessWidget {
  final bool showChat;
  const FeedPage({super.key, required this.showChat});
  @override
  Widget build(BuildContext context) {
    final isAr = AppState.of(context).locale.value.languageCode == 'ar';
    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('projects')
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data?.docs ?? [];
          if (docs.isEmpty) {
            return Center(child: Text(T.of(context, 'noItems')));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, i) {
              final p = Project.fromDoc(docs[i]);

              final statusText = p.adopted
                  ? T.of(context, 'adopted')
                  : T.of(context, 'notAdopted');

              final subtitleParts = <String>[];
              if (p.field.isNotEmpty) {
                subtitleParts.add(p.field);
              }
              subtitleParts.add(
                  '${T.of(context, 'byInnovator')} • ${p.authorName}');
              subtitleParts.add('${_timeAgo(p.createdAt)} • $statusText');

              return Card(
                child: ListTile(
                  leading: const Icon(Icons.article_outlined),
                  title: Text(p.title),
                  subtitle: Text(
                    '${p.desc}\n${subtitleParts.join(' • ')}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ProjectDetailPage(project: p, showChat: showChat),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }
}

class ProjectDetailPage extends StatefulWidget {
  final Project project;
  final bool showChat;

  const ProjectDetailPage({
    super.key,
    required this.project,
    required this.showChat,
  });

  @override
  State<ProjectDetailPage> createState() => _ProjectDetailPageState();
}

class _ProjectDetailPageState extends State<ProjectDetailPage> {
  late bool _adopted;

  @override
  void initState() {
    super.initState();
    _adopted = widget.project.adopted;
  }

  @override
  Widget build(BuildContext context) {
    final isAr = AppState.of(context).locale.value.languageCode == 'ar';
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final canDelete = uid != null && uid == widget.project.author;
    final isCompany = currentUserRole == 'company';

    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.project.title),
          actions: [
            const _LanguageMenu(),
            if (canDelete)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: T.of(context, 'delete'),
                onPressed: () => _confirmDelete(context),
              ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              widget.project.desc,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),

            // adoption status
            Row(
              children: [
                Icon(
                  _adopted ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: _adopted
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).disabledColor,
                ),
                const SizedBox(width: 8),
                Text(
                  _adopted
                      ? T.of(context, 'adopted')
                      : T.of(context, 'notAdopted'),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),

            // company-only toggle
            if (isCompany)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _toggleAdopt,
                  icon: Icon(_adopted ? Icons.undo : Icons.check),
                  label: Text(
                    _adopted
                        ? T.of(context, 'markUnadopted')
                        : T.of(context, 'markAdopted'),
                  ),
                ),
              ),

            const SizedBox(height: 16),

            /// SHOW ATTACHMENTS
            if (widget.project.files.isNotEmpty) ...[
              Text(
                T.of(context, 'attachments'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              ...widget.project.files.map(
                    (f) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.attachment),
                    title: Text(f.name),
                    subtitle: Text(
                      '${f.extension ?? ''}  •  ${formatFileSize(f.size)}',
                    ),
                    trailing: TextButton(
                      onPressed: () => _openAttachment(context, f),
                      child: Text(T.of(context, 'open')),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),

        /// CHAT BUTTON (COMPANY ONLY)
        floatingActionButton: widget.showChat
            ? FloatingActionButton.extended(
          icon: const Icon(Icons.chat_bubble_outline),
          label: Text(T.of(context, 'chat')),
          onPressed: () async {
            final threadId = 'project_${widget.project.id}';
            final threadRef = FirebaseFirestore.instance
                .collection('threads')
                .doc(threadId);

            final exists = (await threadRef.get()).exists;

            if (!exists) {
              await threadRef.set({
                'title': widget.project.title,
                'updatedAt': Timestamp.now(),
                'lastMessage': '',
                'createdBy': currentUserRole,
                'innovatorUnread': 0,
                'companyUnread': 0,
              });
            }

            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatPage(
                  threadId: threadId,
                  title: widget.project.title,
                ),
              ),
            );
          },
        )
            : null,
      ),
    );
  }

  Future<void> _toggleAdopt() async {
    try {
      final newValue = !_adopted;
      await FirebaseFirestore.instance
          .collection('projects')
          .doc(widget.project.id)
          .update({'adopted': newValue});

      setState(() {
        _adopted = newValue;
      });
    } catch (e) {
      debugPrint('Adopt toggle failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update status: $e')),
        );
      }
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final isAr = AppState.of(context).locale.value.languageCode == 'ar';
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
        child: AlertDialog(
          title: Text(T.of(ctx, 'delete')),
          content: Text(T.of(ctx, 'confirmDeleteProject')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(T.of(ctx, 'cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(T.of(ctx, 'confirm')),
            ),
          ],
        ),
      ),
    ) ??
        false;

    if (!shouldDelete) return;

    try {
      final fs = FirebaseFirestore.instance;

      await fs.collection('projects').doc(widget.project.id).delete();

      final threadId = 'project_${widget.project.id}';
      final threadRef = fs.collection('threads').doc(threadId);
      final msgs = await threadRef.collection('messages').get();
      for (final m in msgs.docs) {
        await m.reference.delete();
      }
      await threadRef.delete();

      if (context.mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Project deleted')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }
}

/// ---------- FILE OPEN HELPERS ----------

Future<String> _saveBytesToTemp(Uint8List bytes,
    {required String fileName}) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

Future<String> _saveAssetToTemp(String assetPath, {String? fileName}) async {
  final data = await rootBundle.load(assetPath);
  final name = fileName ?? assetPath.split('/').last;
  return _saveBytesToTemp(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    fileName: name,
  );
}

Future<void> _openAttachment(BuildContext context, Attachment f) async {
  try {
    // 1) local path (session-only)
    if (f.path != null && f.path!.isNotEmpty) {
      await OpenFilex.open(f.path!);
      return;
    }

    // 2) in-memory bytes (session-only)
    if (f.bytes != null && f.bytes!.isNotEmpty) {
      final p = await _saveBytesToTemp(
        f.bytes!,
        fileName:
        f.name.isNotEmpty ? f.name : 'document.${f.extension ?? 'bin'}',
      );
      await OpenFilex.open(p);
      return;
    }

    // 3) Firebase Storage – persistent across restarts
    if (f.storagePath != null && f.storagePath!.isNotEmpty) {
      final ref = FirebaseStorage.instance.ref(f.storagePath!);
      final data = await ref.getData();
      if (data != null) {
        final p = await _saveBytesToTemp(
          data,
          fileName:
          f.name.isNotEmpty ? f.name : 'document.${f.extension ?? 'bin'}',
        );
        await OpenFilex.open(p);
        return;
      }
    }

    // 4) bundled asset
    if (f.assetPath != null) {
      final p = await _saveAssetToTemp(
        f.assetPath!,
        fileName: f.name.isNotEmpty ? f.name : null,
      );
      await OpenFilex.open(p);
      return;
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No file available to open.')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to open: $e')));
    }
  }
}

String formatFileSize(int? bytes) {
  if (bytes == null) return '';
  const kb = 1024;
  const mb = 1024 * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
  return '$bytes B';
}

/// ---------- SEARCH / EXPLORE PAGE ----------
class _SearchPage extends StatefulWidget {
  const _SearchPage({super.key});
  @override
  State<_SearchPage> createState() => _SearchPageState();
}
class _SearchPageState extends State<_SearchPage> {
  final _ideaController = TextEditingController();
  String _selectedField = 'any';
  String _selectedDateRange = 'any';
  final List<String> _fieldOptions = const [
    'any',
    'AI / Technology',
    'Health',
    'Education',
    'Environment',
    'Transportation',
    'Business / FinTech',
    'Other',
  ];
  final List<Map<String, String>> _dateOptions = const [
    {'value': 'any', 'label': 'Any time'},
    {'value': '7d', 'label': 'Last 7 days'},
    {'value': '30d', 'label': 'Last 30 days'},
    {'value': '365d', 'label': 'Last 12 months'},
  ];
  @override
  void dispose() {
    _ideaController.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final isAr = AppState.of(context).locale.value.languageCode == 'ar';
    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // SEARCH FIELD
            TextField(
              controller: _ideaController,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Search by idea / name / keywords',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),

            // FILTERS AS COLUMN
            Column(
              children: [
                DropdownButtonFormField<String>(
                  value: _selectedField,
                  decoration: const InputDecoration(
                    labelText: 'Field',
                    border: OutlineInputBorder(),
                    contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  ),
                  items: _fieldOptions
                      .map(
                        (f) => DropdownMenuItem<String>(
                      value: f,
                      child: Text(
                        f == 'any' ? 'Any field' : f,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                      .toList(),
                  onChanged: (v) => setState(() => _selectedField = v!),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _selectedDateRange,
                  decoration: const InputDecoration(
                    labelText: 'Date',
                    border: OutlineInputBorder(),
                    contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  ),
                  items: _dateOptions
                      .map(
                        (o) => DropdownMenuItem<String>(
                      value: o['value']!,
                      child: Text(
                        o['label']!,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _selectedDateRange = v!),
                ),
              ],
            ),

            const SizedBox(height: 8),

            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () {
                  _ideaController.clear();
                  _selectedField = 'any';
                  _selectedDateRange = 'any';
                  setState(() {});
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Clear filters'),
              ),
            ),

            const SizedBox(height: 8),

            // RESULTS
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('projects')
                    .orderBy('createdAt', descending: true)
                    .snapshots(),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final docs = snap.data?.docs ?? [];
                  final projects = docs.map(Project.fromDoc).toList();
                  final filtered = projects.where(_matchesFilters).toList();

                  if (filtered.isEmpty) {
                    return const Center(child: Text('No matching projects'));
                  }

                  return ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final p = filtered[i];

                      final statusText = p.adopted
                          ? T.of(context, 'adopted')
                          : T.of(context, 'notAdopted');

                      final subtitleParts = <String>[];
                      if (p.field.isNotEmpty) subtitleParts.add(p.field);
                      subtitleParts.add(
                          '${T.of(context, 'byInnovator')} • ${p.authorName}');
                      subtitleParts
                          .add('${_timeAgo(p.createdAt)} • $statusText');

                      return Card(
                        child: ListTile(
                          leading: const Icon(Icons.search),
                          title: Text(p.title),
                          subtitle: Text(
                            '${p.desc}\n${subtitleParts.join(' • ')}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          isThreeLine: true,
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ProjectDetailPage(
                                  project: p,
                                  showChat: currentUserRole == 'company',
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// ---------- FILTER LOGIC ----------
  bool _matchesFilters(Project p) {
    final idea = _ideaController.text.trim().toLowerCase();
    // text search (title + description)
    if (idea.isNotEmpty) {
      final haystack = '${p.title} ${p.desc}'.toLowerCase();
      if (!haystack.contains(idea)) return false;
    }
    // field filter
    if (_selectedField != 'any') {
      if (p.field.toLowerCase() != _selectedField.toLowerCase()) return false;
    }
    // date filter
    if (_selectedDateRange != 'any') {
      final now = DateTime.now();
      late DateTime minDate;
      switch (_selectedDateRange) {
        case '7d':
          minDate = now.subtract(const Duration(days: 7));
          break;
        case '30d':
          minDate = now.subtract(const Duration(days: 30));
          break;
        case '365d':
          minDate = now.subtract(const Duration(days: 365));
          break;
        default:
          minDate = DateTime(2000);
      }
      if (p.createdAt.isBefore(minDate)) return false;
    }
    return true;
  }
  String _timeAgo(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }
}

/// ---------- CHAT THREAD LIST ----------

class ChatThreadsPage extends StatelessWidget {
  const ChatThreadsPage({super.key});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('threads')
          .orderBy('updatedAt', descending: true)
          .limit(20)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Center(child: Text('No messages yet'));
        }
        return ListView.separated(
          padding: const EdgeInsets.all(8),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final d = docs[i].data();
            final id = docs[i].id;
            final title = (d['title'] as String?) ?? id;
            final last = (d['lastMessage'] as String?) ?? '';

            final unread = currentUserRole == 'company'
                ? (d['companyUnread'] as num?)?.toInt() ?? 0
                : (d['innovatorUnread'] as num?)?.toInt() ?? 0;

            return ListTile(
              leading: const CircleAvatar(child: Icon(Icons.forum)),
              title: Text(title),
              subtitle:
              Text(last, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (unread > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.error,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '$unread',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 11),
                      ),
                    ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right),
                ],
              ),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatPage(threadId: id, title: title),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// ---------- CHAT PAGE (ROLE-BASED BUBBLES + ATTACHMENTS + NOTIFICATIONS) ----------

class ChatPage extends StatefulWidget {
  final String threadId;
  final String title;
  const ChatPage({super.key, required this.threadId, required this.title});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scrollController = ScrollController();
  final List<Attachment> _pendingFiles = [];

  int _lastMessageCount = 0;
  bool _initialLoaded = false;

  @override
  void dispose() {
    _input.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _markThreadRead() async {
    final threadRef = FirebaseFirestore.instance
        .collection('threads')
        .doc(widget.threadId);
    try {
      if (currentUserRole == 'innovator') {
        await threadRef.set({'innovatorUnread': 0}, SetOptions(merge: true));
      } else if (currentUserRole == 'company') {
        await threadRef.set({'companyUnread': 0}, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('markThreadRead error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = AppState.of(context).locale.value.languageCode == 'ar';
    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: Column(
          children: [
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('threads')
                    .doc(widget.threadId)
                    .collection('messages')
                    .orderBy('createdAt', descending: false)
                    .snapshots(),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  if (snap.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'Error loading chat:\n${snap.error}',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }

                  final docs = snap.data?.docs ?? [];

                  if (docs.isEmpty) {
                    _markThreadRead();
                    return const Center(child: Text('No messages yet'));
                  }

                  final msgs =
                  docs.map(ChatMessage.fromDoc).toList(growable: false);

                  // Notification banner + mark as read
                  if (!_initialLoaded) {
                    _initialLoaded = true;
                    _lastMessageCount = msgs.length;
                  } else if (msgs.length > _lastMessageCount &&
                      msgs.isNotEmpty) {
                    final last = msgs.last;
                    if (last.role != currentUserRole && mounted) {
                      final fromLabel = currentUserRole == 'company'
                          ? 'Innovator'
                          : 'Company';
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content:
                            Text('New message from $fromLabel')),
                      );
                    }
                    _lastMessageCount = msgs.length;
                  }

                  _markThreadRead();

                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_scrollController.hasClients) {
                      _scrollController.animateTo(
                        _scrollController.position.maxScrollExtent,
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                      );
                    }
                  });

                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 12,
                    ),
                    itemCount: msgs.length,
                    itemBuilder: (_, i) {
                      final m = msgs[i];
                      final mine = m.role == currentUserRole;
                      return _MessageBubble(
                        text: m.text,
                        time: _timeShort(m.createdAt),
                        isMe: mine,
                        attachments: m.attachments,
                        onOpenAttachment: (att) =>
                            _openAttachment(context, att),
                      );
                    },
                  );
                },
              ),
            ),
            const Divider(height: 1),
            _buildInputBar(context),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform
        .pickFiles(allowMultiple: true, withData: true);
    if (result == null) return;

    setState(() {
      _pendingFiles
        ..clear()
        ..addAll(
          result.files.map(
                (pf) => Attachment(
              name: pf.name,
              path: pf.path,
              size: pf.size,
              extension: pf.extension,
              bytes: pf.bytes,
              storagePath: null, // will be set after upload
            ),
          ),
        );
    });
  }

  Widget _buildInputBar(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'anonymous';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pendingFiles.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: _pendingFiles
                      .map(
                        (f) => Chip(
                      label: Text(
                        f.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onDeleted: () {
                        setState(() => _pendingFiles.remove(f));
                      },
                    ),
                  )
                      .toList(),
                ),
              ),
            if (_pendingFiles.isNotEmpty) const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  tooltip: 'Attach file',
                  icon: const Icon(Icons.attach_file),
                  onPressed: _pickFiles,
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Type a message…',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => _send(uid),
                  icon: const Icon(Icons.send),
                  label: Text(T.of(context, 'send')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _timeShort(DateTime dt) {
    final t = TimeOfDay.fromDateTime(dt);
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final m = t.minute.toString().padLeft(2, '0');
    final ap = t.period == DayPeriod.am ? 'AM' : 'PM';
    return '$h:$m $ap';
  }

  /// 🔹 NEW: upload chat attachments to Firebase Storage so they persist
  Future<void> _send(String uid) async {
    final text = _input.text.trim();
    if (text.isEmpty && _pendingFiles.isEmpty) return;

    _input.clear();

    final threads = FirebaseFirestore.instance.collection('threads');
    final threadRef = threads.doc(widget.threadId);
    final messagesRef = threadRef.collection('messages');

    final now = DateTime.now();

    debugPrint(
        'Sending message to thread: ${widget.threadId} as role $currentUserRole with ${_pendingFiles.length} attachment(s)');

    try {
      final storage = FirebaseStorage.instance;
      final uploadedAttachments = <Attachment>[];

      for (final f in _pendingFiles) {
        final bytes = f.bytes;
        if (bytes == null || bytes.isEmpty) continue;

        final ref = storage.ref().child(
          'chat/${widget.threadId}/${now.millisecondsSinceEpoch}_${f.name}',
        );
        await ref.putData(bytes);
        final storagePath = ref.fullPath;

        uploadedAttachments.add(
          Attachment(
            name: f.name,
            path: null,
            size: f.size,
            extension: f.extension,
            bytes: null,
            storagePath: storagePath,
          ),
        );
      }

      final threadUpdate = {
        'title': widget.title,
        'updatedAt': Timestamp.fromDate(now),
        'lastMessage': text.isNotEmpty
            ? text
            : (uploadedAttachments.isNotEmpty ? '[Attachment]' : ''),
      };

      if (currentUserRole == 'innovator') {
        threadUpdate['companyUnread'] = FieldValue.increment(1);
      } else if (currentUserRole == 'company') {
        threadUpdate['innovatorUnread'] = FieldValue.increment(1);
      }

      await threadRef.set(threadUpdate, SetOptions(merge: true));

      await messagesRef.add({
        'text': text,
        'senderId': uid,
        'role': currentUserRole,
        'createdAt': Timestamp.fromDate(now),
        'attachments':
        uploadedAttachments.map((e) => e.toMap()).toList(),
      });

      setState(() {
        _pendingFiles.clear();
      });
    } catch (e) {
      debugPrint('Error sending message: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send: $e')),
        );
      }
    }
  }
}

/// One bubble in the chat.
class _MessageBubble extends StatelessWidget {
  final String text;
  final String time;
  final bool isMe;
  final List<Attachment> attachments;
  final void Function(Attachment) onOpenAttachment;

  const _MessageBubble({
    required this.text,
    required this.time,
    required this.isMe,
    required this.attachments,
    required this.onOpenAttachment,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final bg = isMe ? scheme.primaryContainer : scheme.surfaceVariant;
    final align = isMe ? Alignment.centerRight : Alignment.centerLeft;
    final cross = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(isMe ? 16 : 2),
      bottomRight: Radius.circular(isMe ? 2 : 16),
    );

    return Align(
      alignment: align,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: radius,
        ),
        child: Column(
          crossAxisAlignment: cross,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (text.isNotEmpty) Text(text),
            if (text.isNotEmpty && attachments.isNotEmpty)
              const SizedBox(height: 6),
            if (attachments.isNotEmpty)
              Column(
                crossAxisAlignment: cross,
                children: attachments
                    .map(
                      (a) => TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      alignment: Alignment.centerLeft,
                    ),
                    onPressed: () => onOpenAttachment(a),
                    icon: const Icon(Icons.attach_file, size: 16),
                    label: Text(
                      a.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                    .toList(),
              ),
            const SizedBox(height: 2),
            Text(
              time,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

/// ---------- SUBMIT PROJECT ----------
class SubmitProjectPage extends StatefulWidget {
  final VoidCallback onSubmitted;
  const SubmitProjectPage({super.key, required this.onSubmitted});
  @override
  State<SubmitProjectPage> createState() => _SubmitProjectPageState();
}

class _SubmitProjectPageState extends State<SubmitProjectPage> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _desc = TextEditingController();
  final List<Attachment> _files = [];

  String? _selectedField;

  final List<String> _fieldOptions = const [
    'AI / Technology',
    'Health',
    'Education',
    'Environment',
    'Transportation',
    'Business / FinTech',
    'Other',
  ];

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform
        .pickFiles(allowMultiple: true, withData: true);
    if (result == null) return;
    setState(() {
      _files
        ..clear()
        ..addAll(result.files.map(
              (pf) => Attachment(
            name: pf.name,
            path: pf.path,
            size: pf.size,
            extension: pf.extension,
            bytes: pf.bytes,
            storagePath: null, // will be set after upload
          ),
        ));
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAr = AppState.of(context).locale.value.languageCode == 'ar';
    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(children: [
            Text(T.of(context, 'submitProject'),
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextFormField(
              controller: _title,
              decoration: const InputDecoration(
                  labelText: 'Title', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? T.of(context, 'titleRequired')
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _desc,
              maxLines: 6,
              decoration: const InputDecoration(
                  labelText: 'Description', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? T.of(context, 'descRequired')
                  : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _selectedField,
              decoration: const InputDecoration(
                labelText: 'Field',
                border: OutlineInputBorder(),
              ),
              items: _fieldOptions
                  .map(
                    (f) => DropdownMenuItem<String>(
                  value: f,
                  child: Text(f),
                ),
              )
                  .toList(),
              onChanged: (v) => setState(() => _selectedField = v),
              validator: (v) {
                if (v == null || v.isEmpty) {
                  return 'Please choose a field';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            Row(children: [
              FilledButton.icon(
                onPressed: _pickFiles,
                icon: const Icon(Icons.attach_file),
                label: Text(T.of(context, 'attachments')),
              ),
              const SizedBox(width: 12),
              Text('${_files.length}'),
            ]),
            const SizedBox(height: 8),
            if (_files.isNotEmpty)
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _files.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (_, i) {
                  final f = _files[i];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(
                      f.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                        '${f.extension ?? ''}  •  ${formatFileSize(f.size)}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _files.removeAt(i)),
                      tooltip: 'Remove',
                    ),
                  );
                },
              ),

            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.send),
                label: Text(T.of(context, 'send')),
                onPressed: () async {
                  if (!_formKey.currentState!.validate()) return;
                  final user = FirebaseAuth.instance.currentUser;
                  final uid = user?.uid ?? 'anonymous';
                  final authorName = user?.displayName ?? 'Innovator';
                  final now = DateTime.now();
                  // Upload all attachments to Firebase Storage
                  final storage = FirebaseStorage.instance;
                  final uploaded = <Attachment>[];
                  for (final f in _files) {
                    final bytes = f.bytes;
                    if (bytes == null) continue;
                    final ref = storage.ref().child(
                        'projects/$uid/${now.millisecondsSinceEpoch}_${f.name}');
                    await ref.putData(bytes);
                    final storagePath = ref.fullPath;
                    uploaded.add(Attachment(
                      name: f.name,
                      path: null, // no local path in Firestore
                      size: f.size,
                      extension: f.extension,
                      bytes: null, // not stored
                      storagePath: storagePath, // persisted
                    ));
                  }
                  await FirebaseFirestore.instance.collection('projects').add({
                    'title': _title.text.trim(),
                    'desc': _desc.text.trim(),
                    'author': uid,
                    'authorName': authorName,
                    'createdAt': Timestamp.fromDate(now),
                    'files': uploaded.map((e) => e.toMap()).toList(),
                    'adopted': false,
                    'field': _selectedField!, // required now
                  });
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Submitted!')),
                  );

                  _title.clear();
                  _desc.clear();
                  _files.clear();
                  _selectedField = null;
                  setState(() {});

                  widget.onSubmitted();
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }
}




