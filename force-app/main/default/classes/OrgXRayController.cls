/**
 * Org X-Ray by Virago
 * Read-only health checks for a Salesforce org. Every method returns a JSON string,
 * runs in its own transaction (the LWC calls them one by one) and never changes data.
 * If one check fails, the others still run: errors come back inside the result.
 */
public with sharing class OrgXRayController {

    private static final Integer MAX_ROWS = 200;
    private static final Integer FIELD_CHUNK = 150;
    private static final Integer OLD_API_VERSION = 45;
    private static final Integer MIN_RECORDS_TO_JUDGE = 20;
    private static final Integer MAX_OBJECTS_TO_COUNT = 80;
    // Integration and agent users are system accounts, not seats anyone could give back
    private static final String PAID_LICENSES_ONLY = ' AND (NOT Profile.UserLicense.Name LIKE \'%Integration%\')'
        + ' AND Profile.UserLicense.Name != \'Einstein Agent\'';

    public class CheckResult {
        public String key;
        public Boolean ok = true;
        public String error;
        public Map<String, Object> data = new Map<String, Object>();
        public CheckResult(String key) {
            this.key = key;
        }
        public String fail(Exception e) {
            this.ok = false;
            this.error = e.getMessage();
            return JSON.serialize(this);
        }
        public String done() {
            return JSON.serialize(this);
        }
    }

    // ------------------------------------------------------------------
    // 1. Licenses: active users who haven't logged in for a while
    // ------------------------------------------------------------------
    @AuraEnabled
    public static String checkLicenses(Integer inactiveDays) {
        CheckResult r = new CheckResult('licenses');
        try {
            Integer days = (inactiveDays == null || inactiveDays < 1) ? 90 : inactiveDays;
            Datetime cutoff = Datetime.now().addDays(-days);
            Map<String, Object> binds = new Map<String, Object>{ 'cutoff' => cutoff };

            Map<Id, String> licenseNames = new Map<Id, String>();
            List<Map<String, Object>> licenses = new List<Map<String, Object>>();
            for (SObject ul : Database.query(
                    'SELECT Id, MasterLabel, TotalLicenses, UsedLicenses, Status FROM UserLicense')) {
                licenseNames.put(ul.Id, (String) ul.get('MasterLabel'));
                Integer total = (Integer) ul.get('TotalLicenses');
                if (total != null && total > 0) {
                    licenses.add(new Map<String, Object>{
                        'name' => ul.get('MasterLabel'),
                        'total' => total,
                        'used' => ul.get('UsedLicenses')
                    });
                }
            }

            String whereClause = ' FROM User WHERE IsActive = true AND UserType = \'Standard\''
                + ' AND CreatedDate < :cutoff AND (LastLoginDate = null OR LastLoginDate < :cutoff)'
                + PAID_LICENSES_ONLY;

            Integer inactiveCount = Database.countQueryWithBinds(
                'SELECT COUNT()' + whereClause, binds, AccessLevel.SYSTEM_MODE);

            List<Map<String, Object>> users = new List<Map<String, Object>>();
            for (SObject u : Database.queryWithBinds(
                    'SELECT Id, Name, Username, LastLoginDate, Profile.Name, Profile.UserLicenseId'
                    + whereClause + ' ORDER BY LastLoginDate ASC NULLS FIRST LIMIT ' + MAX_ROWS,
                    binds, AccessLevel.SYSTEM_MODE)) {
                users.add(userRow(u, licenseNames));
            }

            List<Map<String, Object>> byLicense = new List<Map<String, Object>>();
            for (SObject ar : Database.queryWithBinds(
                    'SELECT Profile.UserLicense.Name lic, COUNT(Id) cnt' + whereClause
                    + ' GROUP BY Profile.UserLicense.Name ORDER BY COUNT(Id) DESC',
                    binds, AccessLevel.SYSTEM_MODE)) {
                byLicense.add(new Map<String, Object>{ 'license' => ar.get('lic'), 'count' => ar.get('cnt') });
            }

            Integer activeUsers = Database.countQuery(
                'SELECT COUNT() FROM User WHERE IsActive = true AND UserType = \'Standard\'');

            // Nobody logs in to a sandbox, so its login dates say nothing about real license use
            r.data.put('isSandbox', Database.query('SELECT IsSandbox FROM Organization LIMIT 1')[0].get('IsSandbox'));
            r.data.put('byLicense', byLicense);
            r.data.put('days', days);
            r.data.put('inactiveCount', inactiveCount);
            r.data.put('activeUsers', activeUsers);
            r.data.put('users', users);
            r.data.put('licenses', licenses);
            return r.done();
        } catch (Exception e) {
            return r.fail(e);
        }
    }

    @TestVisible
    private static Map<String, Object> userRow(SObject u, Map<Id, String> licenseNames) {
        SObject prof = u.getSObject('Profile');
        Id licId = prof == null ? null : (Id) prof.get('UserLicenseId');
        return new Map<String, Object>{
            'id' => u.Id,
            'name' => u.get('Name'),
            'username' => u.get('Username'),
            'lastLogin' => u.get('LastLoginDate'),
            'profile' => prof == null ? null : prof.get('Name'),
            'license' => licId == null ? null : licenseNames.get(licId)
        };
    }

    // ------------------------------------------------------------------
    // 2. Automation: Process Builders still active, triggers, old API versions
    // ------------------------------------------------------------------
    @AuraEnabled
    public static String checkAutomation() {
        CheckResult r = new CheckResult('automation');
        try {
            List<SObject> flows;
            Boolean hasNamespaceField = true;
            try {
                flows = Database.query('SELECT ApiName, Label, ProcessType, ApiVersion, LastModifiedDate, NamespacePrefix '
                    + 'FROM FlowDefinitionView WHERE IsActive = true LIMIT 2000');
            } catch (Exception e) {
                hasNamespaceField = false;
                flows = Database.query('SELECT ApiName, Label, ProcessType, ApiVersion, LastModifiedDate '
                    + 'FROM FlowDefinitionView WHERE IsActive = true LIMIT 2000');
            }

            Map<String, Integer> byType = new Map<String, Integer>();
            List<Map<String, Object>> legacy = new List<Map<String, Object>>();
            tallyFlows(flows, hasNamespaceField, byType, legacy);

            // Objects with more than one active trigger
            Map<String, List<String>> triggersByObject = new Map<String, List<String>>();
            Integer oldTriggers = collectTriggers(
                Database.query('SELECT Name, TableEnumOrId, ApiVersion FROM ApexTrigger '
                    + 'WHERE NamespacePrefix = null AND Status = \'Active\''),
                triggersByObject);
            List<Map<String, Object>> multiTrigger = multiTriggerRows(triggersByObject);
            Integer activeTriggers = 0;
            for (List<String> names : triggersByObject.values()) {
                activeTriggers += names.size();
            }

            // Apex classes on very old API versions
            Integer apexClasses = Database.countQuery('SELECT COUNT() FROM ApexClass WHERE NamespacePrefix = null');
            List<Map<String, Object>> oldClasses = new List<Map<String, Object>>();
            for (SObject c : Database.query('SELECT Name, ApiVersion FROM ApexClass WHERE NamespacePrefix = null '
                    + 'AND ApiVersion < 45 ORDER BY ApiVersion ASC LIMIT ' + MAX_ROWS)) {
                oldClasses.add(new Map<String, Object>{
                    'name' => c.get('Name'),
                    'apiVersion' => c.get('ApiVersion')
                });
            }
            Integer oldClassCount = Database.countQuery('SELECT COUNT() FROM ApexClass WHERE NamespacePrefix = null '
                + 'AND ApiVersion < 45');

            r.data.put('oldFlowCount', countOldFlows(flows, hasNamespaceField));
            r.data.put('stuckFlowCount', safeCount('SELECT COUNT() FROM FlowInterview WHERE CreatedDate < LAST_N_DAYS:30'));
            r.data.put('flowsByType', byType);
            r.data.put('legacyProcesses', legacy);
            r.data.put('activeTriggers', activeTriggers);
            r.data.put('multiTriggerObjects', multiTrigger);
            r.data.put('oldTriggerCount', oldTriggers);
            r.data.put('apexClassCount', apexClasses);
            r.data.put('oldClassCount', oldClassCount);
            r.data.put('oldClasses', oldClasses);
            return r.done();
        } catch (Exception e) {
            return r.fail(e);
        }
    }

    @TestVisible
    private static void tallyFlows(List<SObject> flows, Boolean hasNamespaceField,
            Map<String, Integer> byType, List<Map<String, Object>> legacy) {
        for (SObject f : flows) {
            if (hasNamespaceField && f.get('NamespacePrefix') != null) {
                continue; // managed package flows are not the customer's to fix
            }
            String pt = String.valueOf(f.get('ProcessType'));
            byType.put(pt, (byType.containsKey(pt) ? byType.get(pt) : 0) + 1);
            if (pt == 'Workflow' || pt == 'InvocableProcess') {
                legacy.add(new Map<String, Object>{
                    'name' => f.get('Label'),
                    'apiName' => f.get('ApiName'),
                    'lastModified' => f.get('LastModifiedDate')
                });
            }
        }
    }

    @TestVisible
    private static Integer countOldFlows(List<SObject> flows, Boolean hasNamespaceField) {
        Integer old = 0;
        for (SObject f : flows) {
            if (hasNamespaceField && f.get('NamespacePrefix') != null) {
                continue;
            }
            Decimal v = (Decimal) f.get('ApiVersion');
            if (v != null && v < OLD_API_VERSION) {
                old++;
            }
        }
        return old;
    }

    /** Groups trigger names by object and returns how many are on an old API version. */
    @TestVisible
    private static Integer collectTriggers(List<SObject> triggers, Map<String, List<String>> triggersByObject) {
        Integer oldTriggers = 0;
        for (SObject t : triggers) {
            String obj = String.valueOf(t.get('TableEnumOrId'));
            if (!triggersByObject.containsKey(obj)) {
                triggersByObject.put(obj, new List<String>());
            }
            triggersByObject.get(obj).add((String) t.get('Name'));
            Decimal v = (Decimal) t.get('ApiVersion');
            if (v != null && v < 45) {
                oldTriggers++;
            }
        }
        return oldTriggers;
    }

    @TestVisible
    private static List<Map<String, Object>> multiTriggerRows(Map<String, List<String>> triggersByObject) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (String obj : triggersByObject.keySet()) {
            List<String> names = triggersByObject.get(obj);
            if (names.size() > 1) {
                rows.add(new Map<String, Object>{
                    'object' => objectLabel(obj),
                    'triggers' => names
                });
            }
        }
        return rows;
    }

    // ------------------------------------------------------------------
    // 3. Access: who can see and change everything
    // ------------------------------------------------------------------
    @AuraEnabled
    public static String checkAccess() {
        CheckResult r = new CheckResult('access');
        try {
            Map<Id, Map<String, Object>> modifyAll = new Map<Id, Map<String, Object>>();
            for (SObject psa : Database.query('SELECT AssigneeId, Assignee.Name, Assignee.Username, '
                    + 'PermissionSet.Label, PermissionSet.IsOwnedByProfile, PermissionSet.Profile.Name '
                    + 'FROM PermissionSetAssignment WHERE PermissionSet.PermissionsModifyAllData = true '
                    + 'AND Assignee.IsActive = true LIMIT 2000')) {
                addModifyAll(psa, modifyAll);
            }

            Set<Id> viewAll = new Set<Id>();
            for (SObject psa : Database.query('SELECT AssigneeId FROM PermissionSetAssignment '
                    + 'WHERE PermissionSet.PermissionsViewAllData = true AND Assignee.IsActive = true LIMIT 2000')) {
                viewAll.add((Id) psa.get('AssigneeId'));
            }

            Integer activeUsers = Database.countQuery(
                'SELECT COUNT() FROM User WHERE IsActive = true AND UserType = \'Standard\'');

            r.data.put('modifyAllUsers', modifyAll.values());
            r.data.put('modifyAllCount', modifyAll.size());
            r.data.put('viewAllCount', viewAll.size());
            r.data.put('activeUsers', activeUsers);
            return r.done();
        } catch (Exception e) {
            return r.fail(e);
        }
    }

    @TestVisible
    private static void addModifyAll(SObject psa, Map<Id, Map<String, Object>> modifyAll) {
        Id uid = (Id) psa.get('AssigneeId');
        SObject ps = psa.getSObject('PermissionSet');
        SObject assignee = psa.getSObject('Assignee');
        String via;
        if (ps != null && ps.get('IsOwnedByProfile') == true) {
            SObject prof = ps.getSObject('Profile');
            via = 'Profile: ' + (prof == null ? '' : String.valueOf(prof.get('Name')));
        } else {
            via = 'Permission set: ' + (ps == null ? '' : String.valueOf(ps.get('Label')));
        }
        if (!modifyAll.containsKey(uid)) {
            modifyAll.put(uid, new Map<String, Object>{
                'id' => uid,
                'name' => assignee == null ? null : assignee.get('Name'),
                'username' => assignee == null ? null : assignee.get('Username'),
                'via' => new List<String>()
            });
        }
        ((List<String>) modifyAll.get(uid).get('via')).add(via);
    }

    // ------------------------------------------------------------------
    // 4. Duplicate rules on the main objects
    // ------------------------------------------------------------------
    @AuraEnabled
    public static String checkDuplicates() {
        CheckResult r = new CheckResult('duplicates');
        try {
            Map<String, Integer> activeByObject = new Map<String, Integer>{
                'Account' => 0, 'Contact' => 0, 'Lead' => 0
            };
            for (SObject d : Database.query('SELECT DeveloperName, SobjectType, IsActive FROM DuplicateRule')) {
                String obj = String.valueOf(d.get('SobjectType'));
                if (d.get('IsActive') == true && activeByObject.containsKey(obj)) {
                    activeByObject.put(obj, activeByObject.get(obj) + 1);
                }
            }
            r.data.put('activeRules', activeByObject);
            return r.done();
        } catch (Exception e) {
            return r.fail(e);
        }
    }

    // ------------------------------------------------------------------
    // 5. Fields: how full each custom field is in the latest records
    // ------------------------------------------------------------------
    @AuraEnabled
    public static String checkFields(String objectApiName, Integer sampleSize, Integer minAgeDays) {
        CheckResult r = new CheckResult('fields:' + objectApiName);
        try {
            Schema.SObjectType st = Schema.getGlobalDescribe().get(objectApiName);
            if (st == null) {
                throw new XRayException('Object ' + objectApiName + ' was not found.');
            }
            Schema.DescribeSObjectResult d = st.getDescribe();
            r.data.put('object', objectApiName);
            r.data.put('label', d.getLabelPlural());
            if (!d.isAccessible() || !d.isQueryable()) {
                r.data.put('skipped', true);
                return r.done();
            }

            Integer n = (sampleSize == null || sampleSize < 1) ? 500 : Math.min(sampleSize, 2000);
            List<String> fields = new List<String>();
            Map<String, String> labels = new Map<String, String>();
            Set<String> booleans = new Set<String>();
            Integer customTotal = 0;
            Integer ageDays = (minAgeDays == null || minAgeDays < 1) ? 90 : minAgeDays;
            Set<String> tooNew = recentFields(objectApiName, ageDays);
            Integer tooNewCount = 0;

            for (Schema.SObjectField f : d.fields.getMap().values()) {
                Schema.DescribeFieldResult fd = f.getDescribe();
                if (!fd.isCustom()) {
                    continue;
                }
                String name = fd.getName();
                if (name.countMatches('__') > 1) {
                    continue; // managed package field
                }
                customTotal++;
                Schema.DisplayType t = fd.getType();
                if (fd.isCalculated() || fd.isAutoNumber() || !fd.isAccessible()
                        || t == Schema.DisplayType.BASE64
                        || t == Schema.DisplayType.LOCATION
                        || t == Schema.DisplayType.ADDRESS
                        || (t == Schema.DisplayType.TEXTAREA && fd.getLength() > 255)) {
                    continue;
                }
                if (tooNew.contains(name.toLowerCase())) {
                    tooNewCount++;
                    continue; // nobody has had time to fill it in yet
                }
                fields.add(name);
                labels.put(name, fd.getLabel());
                if (t == Schema.DisplayType.BOOLEAN) {
                    booleans.add(name);
                }
            }

            Map<String, Integer> filled = new Map<String, Integer>();
            for (String f : fields) {
                filled.put(f, 0);
            }
            Integer sampled = 0;
            for (Integer i = 0; i < fields.size(); i += FIELD_CHUNK) {
                List<String> chunk = new List<String>();
                for (Integer j = i; j < Math.min(i + FIELD_CHUNK, fields.size()); j++) {
                    chunk.add(fields[j]);
                }
                sampled = 0;
                // SOQL for loop, so wide objects are read in batches and stay under the heap limit
                for (SObject row : Database.query('SELECT ' + String.join(chunk, ', ') + ' FROM '
                        + objectApiName + ' ORDER BY CreatedDate DESC LIMIT ' + n)) {
                    sampled++;
                    tallyRow(row, chunk, booleans, filled);
                }
            }

            r.data.put('customFieldCount', customTotal);
            r.data.put('tooNewCount', tooNewCount);
            r.data.put('minAgeDays', ageDays);
            summarizeFields(r, fields, labels, booleans, filled, sampled);
            return r.done();
        } catch (Exception e) {
            return r.fail(e);
        }
    }

    /**
     * Fields changed in the last few days are too new to judge. Salesforce only exposes the last
     * change date here, so an old field that was edited recently is skipped too. If the org won't
     * answer, every field is scanned rather than failing the check.
     */
    private static Set<String> recentFields(String objectApiName, Integer minAgeDays) {
        try {
            return changedSince(Database.query('SELECT QualifiedApiName, LastModifiedDate FROM FieldDefinition '
                + 'WHERE EntityDefinition.QualifiedApiName = :objectApiName'), Datetime.now().addDays(-minAgeDays));
        } catch (QueryException e) {
            return new Set<String>();
        }
    }

    @TestVisible
    private static Set<String> changedSince(List<SObject> fieldDefinitions, Datetime cutoff) {
        Set<String> names = new Set<String>();
        for (SObject f : fieldDefinitions) {
            Datetime changed = (Datetime) f.get('LastModifiedDate');
            if (changed != null && changed >= cutoff) {
                names.add(((String) f.get('QualifiedApiName')).toLowerCase());
            }
        }
        return names;
    }

    @TestVisible
    private static void tallyRow(SObject row, List<String> chunk, Set<String> booleans, Map<String, Integer> filled) {
        for (String f : chunk) {
            Object v = row.get(f);
            Boolean has = booleans.contains(f) ? (v == true) : (v != null && String.valueOf(v) != '');
            if (has) {
                filled.put(f, filled.get(f) + 1);
            }
        }
    }

    @TestVisible
    private static void summarizeFields(CheckResult r, List<String> fields, Map<String, String> labels,
            Set<String> booleans, Map<String, Integer> filled, Integer sampled) {
        List<FieldStat> stats = new List<FieldStat>();
        Integer neverUsed = 0;
        Integer rarelyUsed = 0;
        if (sampled > 0) {
            for (String f : fields) {
                Decimal filledCount = filled.get(f);
                Decimal pct = (filledCount * 100 / sampled).setScale(1);
                if (pct < 5) {
                    rarelyUsed++;
                    if (filled.get(f) == 0) {
                        neverUsed++;
                    }
                    stats.add(new FieldStat(f, labels.get(f), pct, booleans.contains(f)));
                }
            }
        }
        stats.sort();
        List<FieldStat> top = new List<FieldStat>();
        for (Integer i = 0; i < Math.min(stats.size(), 50); i++) {
            top.add(stats[i]);
        }

        r.data.put('scannedFieldCount', fields.size());
        r.data.put('sampleSize', sampled);
        r.data.put('neverUsedCount', neverUsed);
        r.data.put('rarelyUsedCount', rarelyUsed);
        r.data.put('rarelyUsed', top);
    }

    public class FieldStat implements Comparable {
        public String apiName;
        public String label;
        public Decimal filledPct;
        public Boolean isCheckbox;
        public FieldStat(String apiName, String label, Decimal filledPct, Boolean isCheckbox) {
            this.apiName = apiName;
            this.label = label;
            this.filledPct = filledPct;
            this.isCheckbox = isCheckbox;
        }
        public Integer compareTo(Object other) {
            FieldStat o = (FieldStat) other;
            if (filledPct == o.filledPct) {
                return label.compareTo(o.label);
            }
            return filledPct < o.filledPct ? -1 : 1;
        }
    }

    // ------------------------------------------------------------------
    // 6. Lead flow: lead sources that have gone quiet or are dropping
    // ------------------------------------------------------------------
    @AuraEnabled
    public static String checkLeadFlow() {
        CheckResult r = new CheckResult('leadFlow');
        try {
            if (!Schema.sObjectType.Lead.isAccessible()) {
                r.data.put('skipped', true);
                return r.done();
            }
            Map<String, Integer> last7 = new Map<String, Integer>();
            for (AggregateResult ar : [SELECT LeadSource src, COUNT(Id) cnt FROM Lead
                                       WHERE CreatedDate = LAST_N_DAYS:7 GROUP BY LeadSource]) {
                last7.put(sourceName(ar.get('src')), (Integer) ar.get('cnt'));
            }

            List<Map<String, Object>> sources = new List<Map<String, Object>>();
            Integer quiet = 0;
            Integer dropping = 0;
            Long now = Datetime.now().getTime();
            for (AggregateResult ar : [SELECT LeadSource src, COUNT(Id) cnt, MAX(CreatedDate) lastAt FROM Lead
                                       WHERE CreatedDate = LAST_N_DAYS:60 GROUP BY LeadSource]) {
                String name = sourceName(ar.get('src'));
                Integer recent = last7.containsKey(name) ? last7.get(name) : 0;
                Map<String, Object> row = sourceRow(name, (Integer) ar.get('cnt'), recent,
                    (Datetime) ar.get('lastAt'), now);
                if (row.get('status') == 'quiet') {
                    quiet++;
                } else if (row.get('status') == 'dropping') {
                    dropping++;
                }
                sources.add(row);
            }
            r.data.put('sources', sources);
            r.data.put('quietCount', quiet);
            r.data.put('droppingCount', dropping);
            return r.done();
        } catch (Exception e) {
            return r.fail(e);
        }
    }

    @TestVisible
    private static Map<String, Object> sourceRow(String name, Integer total60, Integer recent, Datetime lastAt, Long now) {
        Decimal hoursSince = lastAt == null ? null
            : (Decimal.valueOf(now - lastAt.getTime()) / 3600000).setScale(1);
        Decimal t60 = total60;
        return new Map<String, Object>{
            'source' => name,
            'last60' => total60,
            'last7' => recent,
            'perDay' => (t60 / 60).setScale(1),
            'lastLead' => lastAt,
            'hoursSinceLast' => hoursSince,
            'status' => classifySource(total60, recent, hoursSince)
        };
    }

    /**
     * quiet    = a source that normally sends at least one lead every two days has been silent
     *            for much longer than its usual gap (and at least 48 hours, to allow for weekends)
     * dropping = a busy source whose last 7 days are under 40% of its usual daily rate
     */
    public static String classifySource(Integer total60, Integer last7, Decimal hoursSinceLast) {
        Decimal total = total60 == null ? 0 : total60;
        Decimal recent = last7 == null ? 0 : last7;
        Decimal perDay = total / 60;
        Decimal recentPerDay = recent / 7;
        if (perDay >= 0.5 && hoursSinceLast != null) {
            Decimal usualGapHours = 24 / perDay;
            Decimal threshold = Math.max(48.0, 3 * usualGapHours);
            if (hoursSinceLast > threshold) {
                return 'quiet';
            }
        }
        if (perDay >= 1 && recentPerDay < perDay * 0.4) {
            return 'dropping';
        }
        return 'ok';
    }

    private static String sourceName(Object raw) {
        return raw == null ? '(No source)' : String.valueOf(raw);
    }

    private static String objectLabel(String tableEnumOrId) {
        Schema.SObjectType st = Schema.getGlobalDescribe().get(tableEnumOrId);
        if (st != null) {
            return st.getDescribe().getLabel();
        }
        return tableEnumOrId.startsWith('01I') ? 'Custom object (' + tableEnumOrId + ')' : tableEnumOrId;
    }

    // ------------------------------------------------------------------
    // 7. Limits: storage and API use
    // ------------------------------------------------------------------
    @AuraEnabled
    public static String checkLimits() {
        CheckResult r = new CheckResult('limits');
        try {
            Map<String, System.OrgLimit> all = OrgLimits.getMap();
            List<Map<String, Object>> rows = new List<Map<String, Object>>();
            for (String name : new List<String>{ 'DataStorageMB', 'FileStorageMB', 'DailyApiRequests' }) {
                System.OrgLimit l = all.get(name);
                if (l != null) {
                    rows.add(limitRow(name, l.getValue(), l.getLimit()));
                }
            }
            r.data.put('limits', rows);
            return r.done();
        } catch (Exception e) {
            return r.fail(e);
        }
    }

    @TestVisible
    private static Map<String, Object> limitRow(String name, Integer used, Integer max) {
        Decimal pct = (max == null || max == 0) ? 0 : (Decimal.valueOf(used) * 100 / max).setScale(1);
        return new Map<String, Object>{ 'name' => name, 'used' => used, 'max' => max, 'pct' => pct };
    }

    // ------------------------------------------------------------------
    // 8. Background jobs that failed in the last 7 days
    // ------------------------------------------------------------------
    @AuraEnabled
    public static String checkJobs() {
        CheckResult r = new CheckResult('jobs');
        try {
            Integer failed = 0;
            List<Map<String, Object>> jobs = new List<Map<String, Object>>();
            for (SObject ar : Database.query('SELECT ApexClass.Name cls, COUNT(Id) cnt FROM AsyncApexJob '
                    + 'WHERE Status = \'Failed\' AND CreatedDate = LAST_N_DAYS:7 '
                    + 'GROUP BY ApexClass.Name ORDER BY COUNT(Id) DESC LIMIT ' + MAX_ROWS)) {
                Integer count = (Integer) ar.get('cnt');
                failed += count;
                jobs.add(new Map<String, Object>{ 'name' => ar.get('cls'), 'count' => count });
            }
            r.data.put('failedCount', failed);
            r.data.put('jobs', jobs);
            return r.done();
        } catch (Exception e) {
            return r.fail(e);
        }
    }

    // ------------------------------------------------------------------
    // 9. Stale data: unused reports, forgotten deals, records nobody owns
    // ------------------------------------------------------------------
    @AuraEnabled
    public static String checkStaleData() {
        CheckResult r = new CheckResult('staleData');
        try {
            r.data.put('reportsTotal', safeCount('SELECT COUNT() FROM Report'));
            r.data.put('reportsUnused', safeCount('SELECT COUNT() FROM Report '
                + 'WHERE LastRunDate = null OR LastRunDate < LAST_N_DAYS:365'));
            r.data.put('oppsPastClose', safeCount('SELECT COUNT() FROM Opportunity '
                + 'WHERE IsClosed = false AND CloseDate < TODAY'));
            r.data.put('accountsInactiveOwner', safeCount('SELECT COUNT() FROM Account WHERE Owner.IsActive = false'));
            r.data.put('leadsInactiveOwner', safeCount('SELECT COUNT() FROM Lead '
                + 'WHERE IsConverted = false AND Owner.IsActive = false'));
            return r.done();
        } catch (Exception e) {
            return r.fail(e);
        }
    }

    /** Returns null when this org or user can't run the query, so the other counts still show. */
    @TestVisible
    private static Integer safeCount(String soql) {
        try {
            return Database.countQuery(soql);
        } catch (QueryException e) {
            return null;
        }
    }

    // ------------------------------------------------------------------
    // 10. Security: powerful permissions, guest write access, failed logins
    // ------------------------------------------------------------------
    @AuraEnabled
    public static String checkSecurity() {
        CheckResult r = new CheckResult('security');
        try {
            r.data.put('manageUsersCount', usersWith('PermissionsManageUsers'));
            r.data.put('authorApexCount', usersWith('PermissionsAuthorApex'));
            r.data.put('guestWriteCount', safeCount('SELECT COUNT() FROM ObjectPermissions '
                + 'WHERE Parent.IsOwnedByProfile = true AND Parent.Profile.UserType = \'Guest\' '
                + 'AND (PermissionsCreate = true OR PermissionsEdit = true OR PermissionsDelete = true)'));

            // LoginHistory can't be filtered by Status, so this reads the latest logins and counts
            List<SObject> logins = Database.query('SELECT Status FROM LoginHistory '
                + 'WHERE LoginTime = LAST_N_DAYS:7 ORDER BY LoginTime DESC LIMIT 2000');
            r.data.put('loginsSampled', logins.size());
            r.data.put('failedLogins', countFailedLogins(logins));
            return r.done();
        } catch (Exception e) {
            return r.fail(e);
        }
    }

    /** permissionField is always one of the constants above, never user input. */
    private static Integer usersWith(String permissionField) {
        try {
            Set<Id> users = new Set<Id>();
            for (SObject psa : Database.query('SELECT AssigneeId FROM PermissionSetAssignment WHERE PermissionSet.'
                    + permissionField + ' = true AND Assignee.IsActive = true '
                    + 'AND Assignee.UserType = \'Standard\' LIMIT 2000')) {
                users.add((Id) psa.get('AssigneeId'));
            }
            return users.size();
        } catch (QueryException e) {
            return null;
        }
    }

    @TestVisible
    private static Integer countFailedLogins(List<SObject> logins) {
        Integer failed = 0;
        for (SObject l : logins) {
            if (l.get('Status') != 'Success') {
                failed++;
            }
        }
        return failed;
    }

    // ------------------------------------------------------------------
    // 11. Data quality: records missing the basics or left untouched
    // ------------------------------------------------------------------
    @AuraEnabled
    public static String checkDataQuality() {
        CheckResult r = new CheckResult('dataQuality');
        try {
            r.data.put('contactsTotal', safeCount('SELECT COUNT() FROM Contact'));
            r.data.put('contactsNoEmail', safeCount('SELECT COUNT() FROM Contact WHERE Email = null'));
            r.data.put('contactsStale', safeCount('SELECT COUNT() FROM Contact WHERE LastModifiedDate < LAST_N_DAYS:730'));
            r.data.put('accountsTotal', safeCount('SELECT COUNT() FROM Account'));
            r.data.put('accountsNoContact', safeCount('SELECT COUNT() FROM Account '
                + 'WHERE Id NOT IN (SELECT AccountId FROM Contact)'));
            r.data.put('accountsStale', safeCount('SELECT COUNT() FROM Account WHERE LastModifiedDate < LAST_N_DAYS:730'));
            return r.done();
        } catch (Exception e) {
            return r.fail(e);
        }
    }

    // ------------------------------------------------------------------
    // 12. The custom objects worth scanning for unused fields
    // ------------------------------------------------------------------
    @AuraEnabled
    public static String listCustomObjects(Integer maxObjects) {
        CheckResult r = new CheckResult('customObjects');
        try {
            List<String> names = new List<String>();
            for (String name : Schema.getGlobalDescribe().keySet()) {
                if (name.endsWith('__c') && name.countMatches('__') == 1) {
                    names.add(name); // a second pair of underscores means a managed package object
                }
            }
            names.sort();

            Map<String, Integer> counts = new Map<String, Integer>();
            for (Integer i = 0; i < Math.min(names.size(), MAX_OBJECTS_TO_COUNT); i++) {
                Schema.DescribeSObjectResult d = Schema.getGlobalDescribe().get(names[i]).getDescribe();
                if (d.isAccessible() && d.isQueryable()) {
                    Integer total = safeCount('SELECT COUNT() FROM ' + d.getName());
                    if (total != null) {
                        counts.put(d.getName(), total);
                    }
                }
            }
            r.data.put('objects', largestObjects(counts, maxObjects == null ? 10 : maxObjects));
            return r.done();
        } catch (Exception e) {
            return r.fail(e);
        }
    }

    /** Objects too small to judge are left out, and the fullest ones come first. */
    @TestVisible
    private static List<String> largestObjects(Map<String, Integer> counts, Integer maxObjects) {
        List<ObjectSize> sizes = new List<ObjectSize>();
        for (String name : counts.keySet()) {
            if (counts.get(name) >= MIN_RECORDS_TO_JUDGE) {
                sizes.add(new ObjectSize(name, counts.get(name)));
            }
        }
        sizes.sort();
        List<String> names = new List<String>();
        for (Integer i = 0; i < Math.min(sizes.size(), maxObjects); i++) {
            names.add(sizes[i].name);
        }
        return names;
    }

    private class ObjectSize implements Comparable {
        private String name;
        private Integer records;
        private ObjectSize(String name, Integer records) {
            this.name = name;
            this.records = records;
        }
        public Integer compareTo(Object other) {
            ObjectSize o = (ObjectSize) other;
            if (records == o.records) {
                return name.compareTo(o.name);
            }
            return records > o.records ? -1 : 1;
        }
    }

    public class XRayException extends Exception {}
}
