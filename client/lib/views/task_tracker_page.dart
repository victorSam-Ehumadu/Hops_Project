import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:client/database/database_helper.dart';

class TaskTrackerPage extends StatefulWidget {
  const TaskTrackerPage({super.key});

  @override
  State<TaskTrackerPage> createState() => _TaskTrackerPageState();
}

class _TaskTrackerPageState extends State<TaskTrackerPage> {
  List<Map<String, dynamic>> _tasks = [];
  DateTime _selectedDate = DateTime.now();
  DateTime _displayMonth = DateTime.now();
  Map<String, Color> _taskDates = {};
  final Set<String> _outsideMonthTaskDates = {};
  Timer? _reminderTimer;
  // Task ids already reminded this session — without this, an overdue,
  // still-incomplete task re-triggers the dialog every 10s forever, and
  // dialogs stack if a previous one is still on screen.
  final Set<String> _remindedTaskIds = {};
  bool _reminderDialogShowing = false;

  @override
  void initState() {
    super.initState();
    _loadTasks();
    _startReminderCheck();
  }

  @override
  void dispose() {
    _reminderTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadTasks() async {
    final tasks = await DatabaseHelper.instance.getTasks(date: _selectedDate);
    setState(() => _tasks = tasks);
    _loadTaskDatesForMonth();
  }

  Color _dotColorForDate(DateTime dueDate) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startOfWeek = today.subtract(Duration(days: today.weekday - 1));
    final endOfWeek = startOfWeek.add(const Duration(days: 6));

    if (!dueDate.isAfter(endOfWeek) && !dueDate.isBefore(startOfWeek)) {
      return Colors.red;
    }
    if (dueDate.month == now.month && dueDate.year == now.year) {
      return Colors.amber;
    }
    return Colors.green;
  }

  Future<void> _loadTaskDatesForMonth() async {
    final tasksThisMonth = await DatabaseHelper.instance.getTasksForMonth(_displayMonth);
    final prevMonth = DateTime(_displayMonth.year, _displayMonth.month - 1, 1);
    final nextMonth = DateTime(_displayMonth.year, _displayMonth.month + 1, 1);
    final tasksPrev = await DatabaseHelper.instance.getTasksForMonth(prevMonth);
    final tasksNext = await DatabaseHelper.instance.getTasksForMonth(nextMonth);

    final dates = <String, Color>{};
    for (final t in tasksThisMonth) {
      if (t[DatabaseHelper.taskColDueDate] != null) {
        final ms = t[DatabaseHelper.taskColDueDate] as int;
        final dt = DateTime.fromMillisecondsSinceEpoch(ms);
        final key = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
        dates[key] = _dotColorForDate(dt);
      }
    }

    final outside = <String>{};
    for (final list in [tasksPrev, tasksNext]) {
      for (final t in list) {
        if (t[DatabaseHelper.taskColDueDate] != null) {
          final ms = t[DatabaseHelper.taskColDueDate] as int;
          final dt = DateTime.fromMillisecondsSinceEpoch(ms);
          final key = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
          outside.add(key);
        }
      }
    }

    setState(() {
      _taskDates = dates;
      _outsideMonthTaskDates.clear();
      _outsideMonthTaskDates.addAll(outside);
    });
  }

  void _startReminderCheck() {
    _reminderTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_reminderDialogShowing) return; // one at a time, never stack
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final task in _tasks) {
        final id = task[DatabaseHelper.taskColId] as String;
        if (task[DatabaseHelper.taskColCompleted] == 0 &&
            task[DatabaseHelper.taskColDueDate] != null &&
            (task[DatabaseHelper.taskColDueDate] as int) <= now &&
            !_remindedTaskIds.contains(id)) {
          _remindedTaskIds.add(id);
          _showReminderDialog(task[DatabaseHelper.taskColTitle]);
          break;
        }
      }
    });
  }

  void _showReminderDialog(String title) {
    _reminderDialogShowing = true;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Task Reminder"),
        content: Text("'$title' is due now!"),
        actions: [
          ElevatedButton(
            onPressed: () {
              _reminderDialogShowing = false;
              Navigator.of(ctx).pop();
            },
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  // ---------- Add / Edit task form ----------
  Future<void> _openTaskForm({Map<String, dynamic>? existing}) async {
    final colors = Theme.of(context).colorScheme;
    final titleCtrl = TextEditingController(text: existing?[DatabaseHelper.taskColTitle] ?? '');
    final descCtrl = TextEditingController(text: existing?[DatabaseHelper.taskColDescription] ?? '');
    DateTime? dueDate = existing?[DatabaseHelper.taskColDueDate] != null
        ? DateTime.fromMillisecondsSinceEpoch(existing![DatabaseHelper.taskColDueDate])
        : null;
    TimeOfDay? startTime;
    TimeOfDay? endTime;

    if (existing?[DatabaseHelper.taskColStartTime] != null) {
      final ms = existing![DatabaseHelper.taskColStartTime] as int;
      startTime = TimeOfDay(hour: ms ~/ 3600000, minute: (ms % 3600000) ~/ 60000);
    }
    if (existing?[DatabaseHelper.taskColEndTime] != null) {
      final ms = existing![DatabaseHelper.taskColEndTime] as int;
      endTime = TimeOfDay(hour: ms ~/ 3600000, minute: (ms % 3600000) ~/ 60000);
    }

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      // StatefulBuilder so picking a date/start/end time visibly updates
      // the button label immediately — without it, dueDate/startTime/
      // endTime were still saved correctly on submit, but the sheet never
      // rebuilt so the labels stayed stuck on "Pick date"/"Start time".
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
        padding: EdgeInsets.only(
          left: 16, right: 16, top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              style: TextStyle(color: colors.onSurface),
              decoration: InputDecoration(
                labelText: "Title",
                labelStyle: TextStyle(color: colors.primary),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colors.primary),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colors.primary, width: 2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descCtrl,
              maxLines: 3,
              style: TextStyle(color: colors.onSurface),
              decoration: InputDecoration(
                labelText: "Description (optional)",
                labelStyle: TextStyle(color: colors.primary),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colors.primary),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colors.primary, width: 2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton.icon(
                  icon: Icon(Icons.calendar_today, color: colors.primary),
                  label: Text(
                    dueDate != null ? dueDate.toString().substring(0, 10) : "Pick date",
                    style: TextStyle(color: colors.primary),
                  ),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: dueDate ?? DateTime.now(),
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) setModalState(() => dueDate = picked);
                  },
                ),
                const Spacer(),
              ],
            ),
            Row(
              children: [
                TextButton.icon(
                  icon: Icon(Icons.access_time, color: colors.primary),
                  label: Text(
                    startTime != null ? startTime!.format(context) : "Start time",
                    style: TextStyle(color: colors.primary),
                  ),
                  onPressed: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: startTime ?? TimeOfDay.now(),
                    );
                    if (picked != null) setModalState(() => startTime = picked);
                  },
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  icon: Icon(Icons.access_time, color: colors.primary),
                  label: Text(
                    endTime != null ? endTime!.format(context) : "End time",
                    style: TextStyle(color: colors.primary),
                  ),
                  onPressed: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: endTime ?? TimeOfDay.now(),
                    );
                    if (picked != null) setModalState(() => endTime = picked);
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.primary,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    final title = titleCtrl.text.trim();
                    if (title.isEmpty) return;
                    final task = <String, dynamic>{
                      DatabaseHelper.taskColTitle: title,
                      DatabaseHelper.taskColDescription: descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
                      DatabaseHelper.taskColDueDate: dueDate?.millisecondsSinceEpoch,
                      DatabaseHelper.taskColStartTime: startTime != null
                          ? (startTime!.hour * 3600000 + startTime!.minute * 60000)
                          : null,
                      DatabaseHelper.taskColEndTime: endTime != null
                          ? (endTime!.hour * 3600000 + endTime!.minute * 60000)
                          : null,
                    };
                    if (existing != null) {
                      await DatabaseHelper.instance.updateTask(existing[DatabaseHelper.taskColId], task);
                    } else {
                      task[DatabaseHelper.taskColId] = const Uuid().v4();
                      task[DatabaseHelper.taskColCompleted] = 0;
                      task[DatabaseHelper.taskColCreatedAt] = DateTime.now().millisecondsSinceEpoch;
                      await DatabaseHelper.instance.insertTask(task);
                    }
                    Navigator.of(context).pop(true);
                  },
                  child: Text(existing != null ? "Update Task" : "Add Task"),
                ),
              ],
            ),
          ],
        ),
      ),
      ),
    );
    if (result == true) await _loadTasks();
  }

  // ---------- Calendar ----------
  int _daysInMonth(DateTime month) {
    return DateTime(month.year, month.month + 1, 0).day;
  }

  DateTime _firstDayOfGrid(DateTime month) {
    final first = DateTime(month.year, month.month, 1);
    return first.subtract(Duration(days: first.weekday - 1));
  }

  void _previousMonth() {
    setState(() {
      _displayMonth = DateTime(_displayMonth.year, _displayMonth.month - 1, 1);
    });
    _loadTaskDatesForMonth();
  }

  void _nextMonth() {
    setState(() {
      _displayMonth = DateTime(_displayMonth.year, _displayMonth.month + 1, 1);
    });
    _loadTaskDatesForMonth();
  }

  Widget _buildCalendar() {
    final colors = Theme.of(context).colorScheme;
    final start = _firstDayOfGrid(_displayMonth);
    final totalDays = 42;
    final today = DateTime.now();

    return Column(
      children: [
        // Month header
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              icon: Icon(Icons.chevron_left, color: colors.primary),
              onPressed: _previousMonth,
            ),
            Flexible(
              child: Text(
                "${_displayMonth.month}/${_displayMonth.year}",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: colors.primary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: Icon(Icons.chevron_right, color: colors.primary),
              onPressed: _nextMonth,
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Day headers
        Row(
          children: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
              .map((d) => Expanded(
            child: Center(
              child: Text(
                d,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                  color: colors.primary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ))
              .toList(),
        ),
        const SizedBox(height: 4),
        // Day grid
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7),
          itemCount: totalDays,
          itemBuilder: (context, index) {
            final date = start.add(Duration(days: index));
            final isSelected = date.day == _selectedDate.day &&
                date.month == _selectedDate.month &&
                date.year == _selectedDate.year;
            final isToday = date.day == today.day &&
                date.month == today.month &&
                date.year == today.year;
            final isCurrentMonth = date.month == _displayMonth.month;
            final dateKey = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

            return GestureDetector(
              onTap: () {
                if (!isCurrentMonth) {
                  setState(() {
                    _displayMonth = DateTime(date.year, date.month, 1);
                  });
                  _loadTaskDatesForMonth();
                }
                setState(() => _selectedDate = date);
                _loadTasks();
              },
              child: Container(
                margin: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: isSelected
                      ? colors.primary
                      : isCurrentMonth
                      ? colors.surface.withOpacity(0.4)
                      : colors.surface.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: isToday ? Border.all(color: colors.primary, width: 2) : null,
                ),
                child: Stack(
                  children: [
                    Center(
                      child: Text(
                        date.day.toString(),
                        style: TextStyle(
                          fontWeight: isToday ? FontWeight.bold : null,
                          color: isSelected
                              ? Colors.white
                              : isCurrentMonth
                              ? colors.onSurface
                              : colors.onSurface.withOpacity(0.4),
                        ),
                      ),
                    ),
                    if (isCurrentMonth && _taskDates.containsKey(dateKey))
                      Positioned(
                        top: 2,
                        right: 2,
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _taskDates[dateKey],
                          ),
                        ),
                      ),
                    if (_outsideMonthTaskDates.contains(dateKey))
                      Positioned(
                        bottom: 1,
                        right: 1,
                        child: Container(
                          width: 4,
                          height: 4,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.green,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  // ---------- Task card ----------
  Widget _buildTaskCard(Map<String, dynamic> task) {
    final colors = Theme.of(context).colorScheme;
    final isComplete = task[DatabaseHelper.taskColCompleted] == 1;
    final dueDateMs = task[DatabaseHelper.taskColDueDate];
    final isOverdue = dueDateMs != null &&
        (dueDateMs as int) <= DateTime.now().millisecondsSinceEpoch &&
        !isComplete;

    final startMs = task[DatabaseHelper.taskColStartTime];
    final endMs = task[DatabaseHelper.taskColEndTime];
    String timeStr = '';
    if (startMs != null && endMs != null) {
      final start = TimeOfDay(hour: (startMs as int) ~/ 3600000, minute: (startMs % 3600000) ~/ 60000);
      final end = TimeOfDay(hour: (endMs as int) ~/ 3600000, minute: (endMs % 3600000) ~/ 60000);
      timeStr = '${start.format(context)} - ${end.format(context)}';
    } else if (startMs != null) {
      final start = TimeOfDay(hour: (startMs as int) ~/ 3600000, minute: (startMs % 3600000) ~/ 60000);
      timeStr = start.format(context);
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: isOverdue ? Colors.red.withOpacity(0.1) : colors.surface.withOpacity(0.6),
      child: ExpansionTile(
        leading: Checkbox(
          value: isComplete,
          onChanged: (_) async {
            await DatabaseHelper.instance.updateTask(
              task[DatabaseHelper.taskColId],
              {DatabaseHelper.taskColCompleted: isComplete ? 0 : 1},
            );
            _loadTasks();
          },
          activeColor: colors.primary,
        ),
        title: Text(
          task[DatabaseHelper.taskColTitle],
          style: TextStyle(
            decoration: isComplete ? TextDecoration.lineThrough : null,
            fontWeight: isOverdue ? FontWeight.bold : null,
            color: colors.onSurface,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: timeStr.isNotEmpty
            ? Text(
          timeStr,
          style: TextStyle(fontSize: 12, color: colors.onSurface.withOpacity(0.7)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        )
            : (dueDateMs != null
            ? Text(
          DateTime.fromMillisecondsSinceEpoch(dueDateMs).toString().substring(0, 10),
          style: TextStyle(fontSize: 12, color: colors.onSurface.withOpacity(0.7)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        )
            : null),
        children: [
          if (task[DatabaseHelper.taskColDescription] != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                task[DatabaseHelper.taskColDescription],
                style: TextStyle(color: colors.onSurface),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                icon: Icon(Icons.edit, size: 18, color: colors.primary),
                label: Text("Edit", style: TextStyle(color: colors.primary)),
                onPressed: () => _openTaskForm(existing: task),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                label: const Text("Delete", style: TextStyle(color: Colors.redAccent)),
                onPressed: () async {
                  await DatabaseHelper.instance.deleteTask(task[DatabaseHelper.taskColId]);
                  _loadTasks();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Flexible(
          child: Text(
            "Task Tracker",
            style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: _buildCalendar(),
          ),
          Divider(color: colors.primary),
          Expanded(
            child: _tasks.isEmpty
                ? Center(
              child: Text(
                "No tasks for this day",
                style: TextStyle(color: colors.onSurface.withOpacity(0.6)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            )
                : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: _tasks.length,
              itemBuilder: (context, index) => _buildTaskCard(_tasks[index]),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: colors.primary,
        foregroundColor: Colors.white,
        shape: const CircleBorder(),
        onPressed: () => _openTaskForm(),
        child: const Icon(Icons.add, size: 28),
      ),
    );
  }
}