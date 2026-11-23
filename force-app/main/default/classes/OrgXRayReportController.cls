/**
 * Org X-Ray by Virago
 * Runs the same read-only checks as the dashboard and lays them out for the PDF report.
 * The score, tier and license cost come from the dashboard, because they depend on what the
 * viewer typed in. Nothing is stored.
 */
public with sharing class OrgXRayReportController {

    // All checks share one transaction here, so wide orgs stop scanning fields before the CPU limit
    private static final Integer CPU_BUDGET_MS = 6000;
    private static final Integer MIN_RECORDS_TO_JUDGE = 20;
    private static final Map<String, String> LIMIT_NAMES = new Map<String, String>{
        'DataStorageMB' => 'Data storage (MB)',
        'FileStorageMB' => 'File storage (MB)',
        'DailyApiRequests' => 'API requests in the last 24 hours'
    };

    public class FixItem {
        public String title { get; private set; }
        public String effort { get; private set; }
        public String how { get; private set; }
        public FixItem(String title, String effort, String how) {
            this.title = title;
            this.effort = effort;
            this.how = how;
        }
    }

    public class Row {
        public String name { get; private set; }
        public String detail { get; private set; }
        public Row(String name, String detail) {
            this.name = name;
            this.detail = detail;
        }
    }

    public class Section {
        public String title { get; private set; }
        public String summary { get; private set; }
        public String error { get; private set; }
        public List<Row> rows { get; private set; }
        public Boolean hasRows {
            get {
                return !rows.isEmpty();
            }
        }
        private Map<String, Object> data;

        public Section(String title, String raw) {
            this.title = title;
            this.rows = new List<Row>();
            if (raw != null) {
                Map<String, Object> r = (Map<String, Object>) JSON.deserializeUntyped(raw);
                if (r.get('ok') == true) {
                    this.data = (Map<String, Object>) r.get('data');
                } else {
                    this.error = String.valueOf(r.get('error'));
                }
            }
        }
        private void add(Object name, String detail) {
            rows.add(new Row(String.valueOf(name), detail));
        }
    }

    public String orgName { get; private set; }
    public String generatedOn { get; private set; }
    public String score { get; private set; }
    public String tier { get; private set; }
    public List<Section> sections { get; private set; }
    public List<FixItem> fixFirst { get; private set; }
    public Boolean hasFixFirst {
        get {
            return !fixFirst.isEmpty();
        }
    }
    public Integer failedCount { get; private set; }

    public OrgXRayReportController() {
        Map<String, String> params = ApexPages.currentPage().getParameters();
        orgName = UserInfo.getOrganizationName();
        generatedOn = Datetime.now().format('yyyy-MM-dd HH:mm');
        score = params.get('score');
        tier = params.get('tier');
        fixFirst = parseFixFirst(params.get('fix'));

        sections = new List<Section>{
            licenses(OrgXRayController.checkLicenses(null), params.get('waste')),
            leadFlow(OrgXRayController.checkLeadFlow()),
            automation(OrgXRayController.checkAutomation()),
            access(OrgXRayController.checkAccess()),
            security(OrgXRayController.checkSecurity()),
            dataQuality(OrgXRayController.checkDataQuality()),
            duplicates(OrgXRayController.checkDuplicates()),
            limitsUsed(OrgXRayController.checkLimits()),
            jobs(OrgXRayController.checkJobs()),
            staleData(OrgXRayController.checkStaleData())
        };
        Integer sample = toInteger(params.get('sample'));
        Integer minAge = toInteger(params.get('minAge'));
        String objects = params.get('objects');
        for (String obj : (String.isBlank(objects) ? new List<String>() : objects.split(','))) {
            if (Limits.getCpuTime() > CPU_BUDGET_MS) {
                Section skipped = new Section('Unused fields on ' + obj, null);
                skipped.summary = 'Skipped in this report to stay within Salesforce limits. See the dashboard.';
                sections.add(skipped);
            } else {
                sections.add(fields(obj, OrgXRayController.checkFields(obj, sample, minAge)));
            }
        }

        failedCount = 0;
        for (Section s : sections) {
            if (s.error != null) {
                failedCount++;
            }
        }
    }

    /** The dashboard's priority list. It only shapes the page, so a broken value just leaves it out. */
    @TestVisible
    private static List<FixItem> parseFixFirst(String value) {
        List<FixItem> items = new List<FixItem>();
        if (String.isBlank(value)) {
            return items;
        }
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(value)) {
                Map<String, Object> f = (Map<String, Object>) o;
                items.add(new FixItem((String) f.get('title'), (String) f.get('effort'), (String) f.get('how')));
            }
        } catch (Exception e) {
            items.clear();
        }
        return items;
    }

    private static Integer toInteger(String value) {
        return value != null && value.isNumeric() ? Integer.valueOf(value) : null;
    }

    private static List<Object> listOf(Map<String, Object> data, String key) {
        Object value = data.get(key);
        return value == null ? new List<Object>() : (List<Object>) value;
    }

    private static String dateOf(Object iso) {
        return iso == null ? 'Never' : String.valueOf(iso).left(10);
    }

    @TestVisible
    private static Section licenses(String raw, String waste) {
        Section s = new Section('Licenses nobody uses', raw);
        if (s.data == null) {
            return s;
        }
        if (s.data.get('isSandbox') == true) {
            s.summary = 'This is a sandbox. People rarely log in here, so run the X-Ray in production to see real license use.';
            return s;
        }
        s.summary = s.data.get('inactiveCount') + ' paid users with no login in ' + s.data.get('days') + ' days'
            + (String.isBlank(waste) ? '.' : ', about ' + waste + ' a year.');
        for (Object o : listOf(s.data, 'users')) {
            Map<String, Object> u = (Map<String, Object>) o;
            Object license = u.get('license') != null ? u.get('license') : u.get('profile');
            s.add(u.get('name'), license + ' · last login ' + dateOf(u.get('lastLogin')));
        }
        return s;
    }

    @TestVisible
    private static Section leadFlow(String raw) {
        Section s = new Section('Lead sources', raw);
        if (s.data == null) {
            return s;
        }
        if (s.data.get('skipped') == true) {
            s.summary = 'Leads are not available for this user.';
            return s;
        }
        if (listOf(s.data, 'sources').isEmpty()) {
            s.summary = 'No leads were created in the last 60 days.';
            return s;
        }
        s.summary = s.data.get('quietCount') + ' gone quiet, ' + s.data.get('droppingCount') + ' dropping.';
        for (Object o : listOf(s.data, 'sources')) {
            Map<String, Object> l = (Map<String, Object>) o;
            s.add(l.get('source'), l.get('status') + ' · ' + l.get('perDay') + ' per day on average · '
                + l.get('last7') + ' in the last 7 days · last lead ' + dateOf(l.get('lastLead')));
        }
        return s;
    }

    @TestVisible
    private static Section automation(String raw) {
        Section s = new Section('Old automation and code', raw);
        if (s.data == null) {
            return s;
        }
        s.summary = s.data.get('apexClassCount') + ' Apex classes, ' + s.data.get('oldClassCount')
            + ' of them on API versions older than 45. ' + s.data.get('activeTriggers') + ' active triggers. '
            + s.data.get('oldFlowCount') + ' flows on old API versions.';
        if (s.data.get('stuckFlowCount') != null) {
            s.summary += ' ' + s.data.get('stuckFlowCount') + ' flows paused for over 30 days.';
        }
        for (Object o : listOf(s.data, 'legacyProcesses')) {
            Map<String, Object> p = (Map<String, Object>) o;
            s.add(p.get('name'), 'Process Builder · last changed ' + dateOf(p.get('lastModified')));
        }
        for (Object o : listOf(s.data, 'multiTriggerObjects')) {
            Map<String, Object> m = (Map<String, Object>) o;
            List<String> names = new List<String>();
            for (Object name : (List<Object>) m.get('triggers')) {
                names.add(String.valueOf(name));
            }
            s.add(m.get('object'), names.size() + ' triggers: ' + String.join(names, ', '));
        }
        return s;
    }

    @TestVisible
    private static Section access(String raw) {
        Section s = new Section('Who can change everything', raw);
        if (s.data == null) {
            return s;
        }
        s.summary = s.data.get('modifyAllCount') + ' of ' + s.data.get('activeUsers')
            + ' active users can modify all data, and ' + s.data.get('viewAllCount') + ' can view all data.';
        for (Object o : listOf(s.data, 'modifyAllUsers')) {
            Map<String, Object> u = (Map<String, Object>) o;
            List<String> via = new List<String>();
            for (Object source : (List<Object>) u.get('via')) {
                via.add(String.valueOf(source));
            }
            s.add(u.get('name'), String.join(via, ' · '));
        }
        return s;
    }

    @TestVisible
    private static Section security(String raw) {
        Section s = new Section('Security', raw);
        if (s.data == null) {
            return s;
        }
        addCount(s, 'Users who can manage users', s.data.get('manageUsersCount'));
        addCount(s, 'Users who can write Apex code', s.data.get('authorApexCount'));
        addCount(s, 'Guest profile write permissions', s.data.get('guestWriteCount'));
        s.add('Failed logins', s.data.get('failedLogins') + ' of the latest ' + s.data.get('loginsSampled')
            + ' logins in the last 7 days');
        return s;
    }

    @TestVisible
    private static Section dataQuality(String raw) {
        Section s = new Section('Data quality', raw);
        if (s.data == null) {
            return s;
        }
        addShare(s, 'Contacts without an email', s.data.get('contactsNoEmail'), s.data.get('contactsTotal'));
        addShare(s, 'Contacts untouched for two years', s.data.get('contactsStale'), s.data.get('contactsTotal'));
        addShare(s, 'Accounts without a contact', s.data.get('accountsNoContact'), s.data.get('accountsTotal'));
        addShare(s, 'Accounts untouched for two years', s.data.get('accountsStale'), s.data.get('accountsTotal'));
        return s;
    }

    private static void addCount(Section s, String name, Object count) {
        if (count != null) {
            s.add(name, String.valueOf(count));
        }
    }

    private static void addShare(Section s, String name, Object count, Object total) {
        if (count != null && total != null) {
            s.add(name, count + ' of ' + total);
        }
    }

    @TestVisible
    private static Section duplicates(String raw) {
        Section s = new Section('Duplicate rules', raw);
        if (s.data == null) {
            return s;
        }
        Map<String, Object> rules = (Map<String, Object>) s.data.get('activeRules');
        for (String obj : rules.keySet()) {
            s.add(obj, rules.get(obj) == 0 ? 'No active rule' : rules.get(obj) + ' active');
        }
        return s;
    }

    @TestVisible
    private static Section limitsUsed(String raw) {
        Section s = new Section('Storage and API use', raw);
        if (s.data == null) {
            return s;
        }
        for (Object o : listOf(s.data, 'limits')) {
            Map<String, Object> l = (Map<String, Object>) o;
            String name = (String) l.get('name');
            s.add(LIMIT_NAMES.containsKey(name) ? LIMIT_NAMES.get(name) : name,
                l.get('used') + ' of ' + l.get('max') + ' used (' + l.get('pct') + '%)');
        }
        return s;
    }

    @TestVisible
    private static Section jobs(String raw) {
        Section s = new Section('Failed background jobs', raw);
        if (s.data == null) {
            return s;
        }
        s.summary = s.data.get('failedCount') + ' failed in the last 7 days.';
        for (Object o : listOf(s.data, 'jobs')) {
            Map<String, Object> j = (Map<String, Object>) o;
            s.add(j.get('name') == null ? 'Unnamed job' : j.get('name'), 'failed ' + j.get('count') + ' times');
        }
        return s;
    }

    @TestVisible
    private static Section staleData(String raw) {
        Section s = new Section('Forgotten records and reports', raw);
        if (s.data == null) {
            return s;
        }
        Map<String, String> labels = new Map<String, String>{
            'oppsPastClose' => 'Open deals past their close date',
            'accountsInactiveOwner' => 'Accounts owned by inactive users',
            'leadsInactiveOwner' => 'Open leads owned by inactive users'
        };
        for (String key : labels.keySet()) {
            if (s.data.get(key) != null) {
                s.add(labels.get(key), String.valueOf(s.data.get(key)));
            }
        }
        if (s.data.get('reportsUnused') != null) {
            s.add('Reports not run in a year', s.data.get('reportsUnused') + ' of ' + s.data.get('reportsTotal'));
        }
        return s;
    }

    @TestVisible
    private static Section fields(String obj, String raw) {
        Section s = new Section('Unused fields on ' + obj, raw);
        if (s.data == null) {
            return s;
        }
        if (s.data.get('skipped') == true) {
            s.summary = 'Not available for this user.';
            return s;
        }
        Integer sampled = (Integer) s.data.get('sampleSize');
        if (sampled < MIN_RECORDS_TO_JUDGE) {
            s.summary = 'Only ' + sampled + ' records, too few to judge.';
            return s;
        }
        s.summary = s.data.get('rarelyUsedCount') + ' of ' + s.data.get('scannedFieldCount')
            + ' custom fields are filled in under 5% of the latest ' + sampled + ' records ('
            + s.data.get('neverUsedCount') + ' never).';
        Integer tooNew = (Integer) s.data.get('tooNewCount');
        if (tooNew != null && tooNew > 0) {
            s.summary += ' ' + tooNew + ' changed in the last ' + s.data.get('minAgeDays')
                + ' days were skipped as too new to judge.';
        }
        for (Object o : listOf(s.data, 'rarelyUsed')) {
            Map<String, Object> f = (Map<String, Object>) o;
            s.add(f.get('label'), f.get('apiName') + ' · filled ' + f.get('filledPct') + '%');
        }
        return s;
    }
}
