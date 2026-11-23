import { LightningElement } from 'lwc';
import checkLicenses from '@salesforce/apex/OrgXRayController.checkLicenses';
import checkAutomation from '@salesforce/apex/OrgXRayController.checkAutomation';
import checkAccess from '@salesforce/apex/OrgXRayController.checkAccess';
import checkDuplicates from '@salesforce/apex/OrgXRayController.checkDuplicates';
import checkFields from '@salesforce/apex/OrgXRayController.checkFields';
import checkLeadFlow from '@salesforce/apex/OrgXRayController.checkLeadFlow';
import checkLimits from '@salesforce/apex/OrgXRayController.checkLimits';
import checkJobs from '@salesforce/apex/OrgXRayController.checkJobs';
import checkStaleData from '@salesforce/apex/OrgXRayController.checkStaleData';
import checkSecurity from '@salesforce/apex/OrgXRayController.checkSecurity';
import checkDataQuality from '@salesforce/apex/OrgXRayController.checkDataQuality';
import listCustomObjects from '@salesforce/apex/OrgXRayController.listCustomObjects';

const BOOKING_URL = 'https://getvirago.com';
const FIELD_OBJECTS = ['Account', 'Contact', 'Lead', 'Opportunity', 'Case'];
const SAMPLE_SIZE = 2000;
const MIN_FIELD_AGE_DAYS = 90;
const MIN_RECORDS_TO_JUDGE = 20;
const INACTIVE_DAYS = 90;
const LIST_LIMIT = 10;
const MAX_CUSTOM_OBJECTS = 10;
const FIX_FIRST_LIMIT = 5;
const EFFORT_WEIGHT = { Quick: 1, 'Some work': 2, 'Bigger job': 3 };
// Starting points only. Salesforce doesn't share contract prices with the org, so people type their own.
const DEFAULT_PRICES = { Salesforce: 150, 'Salesforce Platform': 25 };
const LIMIT_NAMES = {
    DataStorageMB: 'Data storage (MB)',
    FileStorageMB: 'File storage (MB)',
    DailyApiRequests: 'API requests in the last 24 hours'
};

const TIERS = [
    { min: 85, name: 'Squeaky clean', text: 'This org is in great shape. Keep the habits that got it here.' },
    { min: 65, name: 'A little dusty', text: 'Mostly healthy, with a few things that will grow if nobody looks at them.' },
    { min: 40, name: 'Messy but fixable', text: 'Like most orgs out there. A focused cleanup would make a real difference.' },
    { min: 0, name: 'Needs attention', text: 'This org is working hard to hold together. Everything below can be fixed.' }
];

const RING_SIZE = 168;
const RING_STROKE = 13;
const RING_RADIUS = (RING_SIZE - RING_STROKE) / 2;
const RING_CIRC = 2 * Math.PI * RING_RADIUS;

function fmtDate(iso) {
    if (!iso) return 'Never';
    const d = new Date(iso);
    return isNaN(d) ? '—' : d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
}
function fmtHours(h) {
    if (h === null || h === undefined) return '—';
    if (h < 1) return 'under an hour ago';
    if (h < 48) return Math.round(h) + ' hours ago';
    return Math.round(h / 24) + ' days ago';
}
function money(n) {
    return '$' + Math.round(n).toLocaleString('en-US');
}
function share(part, total) {
    return total >= MIN_RECORDS_TO_JUDGE ? (part || 0) / total : 0;
}
function scoreColor(p) {
    if (p >= 85) return 'var(--xr-good)';
    if (p >= 65) return 'var(--xr-teal)';
    if (p >= 40) return 'var(--xr-warn)';
    return 'var(--xr-bad)';
}

export default class OrgXRay extends LightningElement {
    licensePrices = {};
    running = false;
    hasResult = false;
    steps = [];
    results = {};
    scanObjects = FIELD_OBJECTS;
    bookingUrl = BOOKING_URL;

    get showIntro() {
        return !this.running && !this.hasResult;
    }
    get runLabel() {
        if (this.running) return 'Scanning…';
        return this.hasResult ? 'Scan again' : 'Run the X-Ray';
    }

    handlePrice(event) {
        const v = Number(event.target.value);
        this.licensePrices = { ...this.licensePrices, [event.target.dataset.license]: isNaN(v) || v < 0 ? 0 : v };
    }

    // ---------------- scanning ----------------
    async run() {
        this.running = true;
        this.hasResult = false;
        this.results = {};
        const plan = [
            { key: 'licenses', label: 'Licenses and inactive users', call: () => checkLicenses({ inactiveDays: INACTIVE_DAYS }) },
            { key: 'automation', label: 'Process Builders, triggers and old code', call: () => checkAutomation() },
            { key: 'leadFlow', label: 'Lead sources that went quiet', call: () => checkLeadFlow() },
            { key: 'access', label: 'Who has full admin access', call: () => checkAccess() },
            { key: 'duplicates', label: 'Duplicate rules', call: () => checkDuplicates() },
            { key: 'limits', label: 'Storage and API use', call: () => checkLimits() },
            { key: 'jobs', label: 'Failed background jobs', call: () => checkJobs() },
            { key: 'staleData', label: 'Unused reports and forgotten records', call: () => checkStaleData() },
            { key: 'security', label: 'Security', call: () => checkSecurity() },
            { key: 'dataQuality', label: 'Data quality', call: () => checkDataQuality() }
        ];
        this.steps = plan.map((p) => ({ key: p.key, label: p.label, state: 'waiting', cls: 'step waiting', icon: 'utility:clock' }));
        this.scanObjects = [...FIELD_OBJECTS, ...(await this.customObjects())];
        this.scanObjects.forEach((obj) => {
            plan.push({
                key: 'fields:' + obj,
                label: 'Unused fields on ' + obj,
                call: () => checkFields({ objectApiName: obj, sampleSize: SAMPLE_SIZE, minAgeDays: MIN_FIELD_AGE_DAYS })
            });
        });
        this.steps = plan.map((p) => ({ key: p.key, label: p.label, state: 'waiting', cls: 'step waiting', icon: 'utility:clock' }));

        const collected = {};
        for (let i = 0; i < plan.length; i++) {
            this.setStep(i, 'running');
            try {
                // eslint-disable-next-line no-await-in-loop
                const raw = await plan[i].call();
                collected[plan[i].key] = JSON.parse(raw);
                this.setStep(i, collected[plan[i].key].ok ? 'done' : 'error');
            } catch (e) {
                collected[plan[i].key] = { key: plan[i].key, ok: false, error: this.errorText(e), data: {} };
                this.setStep(i, 'error');
            }
        }
        this.results = collected;
        this.running = false;
        this.hasResult = true;
        // let the ring draw from empty to its value
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.ringReady = true;
        }, 60);
    }

    ringReady = false;

    // A failure here only means fewer objects get scanned, so it never stops the run
    async customObjects() {
        try {
            const r = JSON.parse(await listCustomObjects({ maxObjects: MAX_CUSTOM_OBJECTS }));
            return r.ok ? r.data.objects : [];
        } catch (e) {
            return [];
        }
    }

    setStep(i, state) {
        const icons = { waiting: 'utility:clock', running: 'utility:sync', done: 'utility:success', error: 'utility:warning' };
        this.steps = this.steps.map((s, idx) => (idx === i ? { ...s, state, cls: 'step ' + state, icon: icons[state] } : s));
    }

    errorText(e) {
        if (e && e.body && e.body.message) return e.body.message;
        if (e && e.message) return e.message;
        return 'Unknown error';
    }

    // ---------------- result helpers ----------------
    data(key) {
        const r = this.results[key];
        return r && r.ok ? r.data : null;
    }
    error(key) {
        const r = this.results[key];
        return r && !r.ok ? r.error : null;
    }

    get inactiveCount() {
        const d = this.data('licenses');
        return d ? d.inactiveCount : 0;
    }
    get isSandbox() {
        const d = this.data('licenses');
        return Boolean(d && d.isSandbox);
    }
    get licenseRows() {
        const d = this.data('licenses');
        if (!d) return [];
        return d.byLicense.map((b) => {
            const name = b.license || 'Other';
            const price = name in this.licensePrices ? this.licensePrices[name] : DEFAULT_PRICES[name] || 0;
            return { key: name, name, count: b.count, price, detail: `${b.count} unused` };
        });
    }
    get yearlyWaste() {
        return this.licenseRows.reduce((sum, r) => sum + r.count * r.price * 12, 0);
    }
    get legacyCount() {
        const d = this.data('automation');
        return d ? d.legacyProcesses.length : 0;
    }
    get quietCount() {
        const d = this.data('leadFlow');
        return d && !d.skipped ? d.quietCount : 0;
    }
    get droppingCount() {
        const d = this.data('leadFlow');
        return d && !d.skipped ? d.droppingCount : 0;
    }
    get modifyAllCount() {
        const d = this.data('access');
        return d ? d.modifyAllCount : 0;
    }
    get fieldTotals() {
        let rarely = 0;
        let never = 0;
        this.scanObjects.forEach((o) => {
            const d = this.data('fields:' + o);
            if (d && !d.skipped && d.sampleSize >= 20) {
                rarely += d.rarelyUsedCount;
                never += d.neverUsedCount;
            }
        });
        return { rarely, never };
    }
    get missingDupRules() {
        const d = this.data('duplicates');
        if (!d) return [];
        return Object.keys(d.activeRules).filter((k) => d.activeRules[k] === 0);
    }
    get multiTriggerCount() {
        const d = this.data('automation');
        return d ? d.multiTriggerObjects.length : 0;
    }
    get oldClassCount() {
        const d = this.data('automation');
        return d ? d.oldClassCount : 0;
    }

    // ---------------- score ----------------
    /** Everything that costs points. The score and the "fix these first" list both come from here. */
    get findings() {
        const items = [];
        const add = (points, title, effort, how) => {
            if (points > 0) items.push({ key: title, points, title, effort, how });
        };
        if (!this.isSandbox) {
            add(
                Math.min(this.inactiveCount * 2, 15),
                `${this.inactiveCount} paid users haven't logged in for ${INACTIVE_DAYS} days`,
                'Quick',
                'Confirm with their managers, deactivate them and lower your license count at the next renewal.'
            );
        }
        if (this.legacyCount > 0) {
            add(
                Math.min(5 + this.legacyCount, 15),
                `${this.legacyCount} Process Builders are still running`,
                'Bigger job',
                'Salesforce no longer supports them. Move them to record-triggered flows with the Migrate to Flow tool.'
            );
        }
        add(
            Math.min(this.multiTriggerCount * 3, 9),
            `${this.multiTriggerCount} objects have more than one trigger`,
            'Some work',
            'Combine them into one trigger per object, so they run in a predictable order.'
        );
        add(
            Math.min(Math.ceil(this.oldClassCount / 2), 8),
            `${this.oldClassCount} Apex classes are on very old API versions`,
            'Some work',
            'Raise the API version one class at a time and run the tests after each change.'
        );
        add(
            Math.min(Math.max(this.modifyAllCount - 3, 0) * 2, 12),
            `${this.modifyAllCount} users can change all data`,
            'Quick',
            'Keep this to a few admins. Give everyone else only the access their job needs.'
        );
        add(
            this.missingDupRules.length * 3,
            `No active duplicate rule on ${this.missingDupRules.join(', ')}`,
            'Quick',
            'Turn on the standard duplicate rules in Setup, starting in alert mode.'
        );
        add(
            Math.min(Math.ceil(this.fieldTotals.rarely / 4), 15),
            `${this.fieldTotals.rarely} custom fields are almost never filled in`,
            'Some work',
            'Export the list, ask the people who use each object, and remove what nobody needs.'
        );
        add(
            Math.min(this.quietCount * 8 + this.droppingCount * 3, 16),
            `${this.quietCount + this.droppingCount} lead sources went quiet or dropped`,
            'Some work',
            'Check the web forms, ads and integrations behind them. Silence often means something broke.'
        );
        add(
            Math.min(this.failedJobCount * 2, 8),
            `${this.failedJobCount} background jobs failed this week`,
            'Some work',
            'Open Apex Jobs in Setup, read the errors and fix the most frequent one first.'
        );
        add(
            Math.min(this.fullLimitCount * 4, 8),
            `${this.fullLimitCount} org limits are almost used up`,
            'Some work',
            'Archive or delete old data, or look at what is using the API, before Salesforce starts blocking work.'
        );
        add(
            Math.min(Math.ceil(this.staleCount / 25), 6),
            `${this.staleCount} deals and records were left behind`,
            'Quick',
            'Update old close dates and reassign records owned by people who have left.'
        );
        const sec = this.data('security');
        if (sec) {
            add(
                Math.min(Math.max((sec.manageUsersCount || 0) - 3, 0), 6),
                `${sec.manageUsersCount} users can manage other users`,
                'Quick',
                'Anyone with this permission can raise their own access. Keep it to a few admins.'
            );
            add(
                Math.min(Math.max((sec.authorApexCount || 0) - 3, 0), 6),
                `${sec.authorApexCount} users can write Apex code`,
                'Quick',
                'Remove it from anyone who is not an active developer.'
            );
            add(
                Math.min((sec.guestWriteCount || 0) * 3, 12),
                `Guest users can change data on ${sec.guestWriteCount} objects`,
                'Some work',
                'People who are not logged in should almost never edit records. Review each guest profile.'
            );
            add(
                Math.min(Math.ceil((sec.failedLogins || 0) / 25), 6),
                `${sec.failedLogins} failed logins in the last 7 days`,
                'Quick',
                'Open Login History in Setup and look for one user or address behind most of them.'
            );
        }
        const dq = this.data('dataQuality');
        if (dq) {
            add(
                share(dq.contactsNoEmail, dq.contactsTotal) >= 0.2 ? 4 : 0,
                `${dq.contactsNoEmail} of ${dq.contactsTotal} contacts have no email`,
                'Some work',
                'Make email required on new contacts and fill in the most important ones first.'
            );
            add(
                share(dq.accountsNoContact, dq.accountsTotal) >= 0.2 ? 3 : 0,
                `${dq.accountsNoContact} of ${dq.accountsTotal} accounts have no contact`,
                'Some work',
                'Add the main contact for accounts you still work with, and archive the rest.'
            );
            add(
                share(dq.accountsStale, dq.accountsTotal) >= 0.5 ? 3 : 0,
                `${dq.accountsStale} of ${dq.accountsTotal} accounts haven't changed in two years`,
                'Some work',
                'Decide which are still real customers and archive the others.'
            );
        }
        return items;
    }
    get fixFirst() {
        return [...this.findings]
            .sort((a, b) => b.points / EFFORT_WEIGHT[b.effort] - a.points / EFFORT_WEIGHT[a.effort])
            .slice(0, FIX_FIRST_LIMIT)
            .map((f) => ({
                ...f,
                pill: `+${f.points} points · ${f.effort}`,
                pillCls: 'pill ' + (f.effort === 'Quick' ? 'good' : 'warn')
            }));
    }
    get hasFixFirst() {
        return this.fixFirst.length > 0;
    }
    get score() {
        const lost = this.findings.reduce((sum, f) => sum + f.points, 0);
        return Math.max(0, Math.min(100, Math.round(100 - lost)));
    }
    get tier() {
        return TIERS.find((t) => this.score >= t.min);
    }
    get ringSize() {
        return RING_SIZE;
    }
    get ringViewBox() {
        return `0 0 ${RING_SIZE} ${RING_SIZE}`;
    }
    get ringCenter() {
        return RING_SIZE / 2;
    }
    get ringRadius() {
        return RING_RADIUS;
    }
    get ringStroke() {
        return RING_STROKE;
    }
    get ringTransform() {
        return `rotate(-90 ${RING_SIZE / 2} ${RING_SIZE / 2})`;
    }
    get ringValStyle() {
        const offset = this.ringReady ? RING_CIRC * (1 - this.score / 100) : RING_CIRC;
        return `stroke:${scoreColor(this.score)};stroke-dasharray:${RING_CIRC};stroke-dashoffset:${offset};`;
    }

    // ---------------- tiles ----------------
    get tiles() {
        const t = [
            {
                key: 'money',
                value: this.isSandbox ? 'n/a' : money(this.yearlyWaste),
                label: 'per year on licenses nobody uses',
                sub: this.isSandbox
                    ? 'Sandbox logins say nothing about real use'
                    : `${this.inactiveCount} paid users with no login in ${INACTIVE_DAYS} days`,
                cls: 'tile ' + (this.isSandbox ? 'good' : this.inactiveCount > 0 ? 'bad' : 'good')
            },
            {
                key: 'legacy',
                value: String(this.legacyCount),
                label: 'Process Builders still running',
                sub: 'No longer supported by Salesforce',
                cls: 'tile ' + (this.legacyCount > 0 ? 'warn' : 'good')
            },
            {
                key: 'quiet',
                value: this.hasLeadSources ? String(this.quietCount + this.droppingCount) : 'n/a',
                label: 'lead sources gone quiet or dropping',
                sub: this.hasLeadSources ? 'Compared with the last 60 days' : 'No leads in the last 60 days',
                cls: 'tile ' + (this.quietCount > 0 ? 'bad' : this.droppingCount > 0 ? 'warn' : 'good')
            },
            {
                key: 'admins',
                value: String(this.modifyAllCount),
                label: 'users can change everything',
                sub: 'Modify All Data permission',
                cls: 'tile ' + (this.modifyAllCount > 3 ? 'warn' : 'good')
            },
            {
                key: 'fields',
                value: String(this.fieldTotals.rarely),
                label: 'custom fields almost never filled',
                sub: `Under 5% of the latest ${SAMPLE_SIZE} records`,
                cls: 'tile ' + (this.fieldTotals.rarely > 10 ? 'warn' : 'good')
            }
        ];
        return t;
    }

    // ---------------- sections ----------------
    get inactiveUsers() {
        const d = this.data('licenses');
        if (!d) return [];
        return d.users.slice(0, LIST_LIMIT).map((u) => ({
            key: u.id,
            name: u.name,
            detail: (u.license || u.profile || '') + ' · last login ' + fmtDate(u.lastLogin)
        }));
    }
    get inactiveMore() {
        const n = this.inactiveCount - this.inactiveUsers.length;
        return n > 0 ? `and ${n} more` : '';
    }
    get failedChecks() {
        return Object.values(this.results).filter((r) => !r.ok).length;
    }
    get partialNote() {
        const n = this.failedChecks;
        if (n === 0) return '';
        return `${n} ${n === 1 ? 'check' : 'checks'} could not run, so this score is incomplete. See the errors below.`;
    }

    get failedJobCount() {
        const d = this.data('jobs');
        return d ? d.failedCount : 0;
    }
    get jobRows() {
        const d = this.data('jobs');
        if (!d) return [];
        return d.jobs.slice(0, LIST_LIMIT).map((j, i) => ({
            key: 'job-' + i,
            name: j.name || 'Unnamed job',
            detail: `failed ${j.count} ${j.count === 1 ? 'time' : 'times'} in the last 7 days`
        }));
    }
    get hasJobRows() {
        return this.jobRows.length > 0;
    }
    get jobsError() {
        return this.error('jobs');
    }

    get limitRows() {
        const d = this.data('limits');
        if (!d) return [];
        return d.limits.map((l) => ({
            key: l.name,
            name: LIMIT_NAMES[l.name] || l.name,
            detail: `${l.used.toLocaleString()} of ${l.max.toLocaleString()} used (${l.pct}%)`,
            pill: l.pct >= 90 ? 'Almost full' : l.pct >= 75 ? 'Watch this' : 'Fine',
            pillCls: 'pill ' + (l.pct >= 90 ? 'bad' : l.pct >= 75 ? 'warn' : 'good')
        }));
    }
    get fullLimitCount() {
        const d = this.data('limits');
        return d ? d.limits.filter((l) => l.pct >= 90).length : 0;
    }
    get limitsError() {
        return this.error('limits');
    }

    get staleCount() {
        const d = this.data('staleData');
        if (!d) return 0;
        return (d.oppsPastClose || 0) + (d.accountsInactiveOwner || 0) + (d.leadsInactiveOwner || 0);
    }
    get staleRows() {
        const d = this.data('staleData');
        if (!d) return [];
        const rows = [
            { key: 'opps', name: 'Open deals past their close date', count: d.oppsPastClose },
            { key: 'accounts', name: 'Accounts owned by inactive users', count: d.accountsInactiveOwner },
            { key: 'leads', name: 'Open leads owned by inactive users', count: d.leadsInactiveOwner },
            {
                key: 'reports',
                name: 'Reports not run in a year',
                count: d.reportsUnused,
                suffix: ` of ${d.reportsTotal}`
            }
        ];
        return rows
            .filter((r) => r.count !== null && r.count !== undefined)
            .map((r) => ({ key: r.key, name: r.name, detail: r.count.toLocaleString() + (r.suffix || '') }));
    }
    get securityRows() {
        const d = this.data('security');
        if (!d) return [];
        const rows = [
            { key: 'users', name: 'Users who can manage users', count: d.manageUsersCount },
            { key: 'apex', name: 'Users who can write Apex code', count: d.authorApexCount },
            { key: 'guest', name: 'Guest profile write permissions', count: d.guestWriteCount },
            {
                key: 'logins',
                name: 'Failed logins',
                count: d.failedLogins,
                suffix: ` of the latest ${d.loginsSampled} logins in the last 7 days`
            }
        ];
        return rows
            .filter((r) => r.count !== null && r.count !== undefined)
            .map((r) => ({ key: r.key, name: r.name, detail: r.count.toLocaleString() + (r.suffix || '') }));
    }
    get securityError() {
        return this.error('security');
    }

    get dataQualityRows() {
        const d = this.data('dataQuality');
        if (!d) return [];
        const rows = [
            { key: 'noemail', name: 'Contacts without an email', count: d.contactsNoEmail, total: d.contactsTotal },
            { key: 'cstale', name: 'Contacts untouched for two years', count: d.contactsStale, total: d.contactsTotal },
            { key: 'nocontact', name: 'Accounts without a contact', count: d.accountsNoContact, total: d.accountsTotal },
            { key: 'astale', name: 'Accounts untouched for two years', count: d.accountsStale, total: d.accountsTotal }
        ];
        return rows
            .filter((r) => r.count !== null && r.count !== undefined && r.total !== null && r.total !== undefined)
            .map((r) => ({ key: r.key, name: r.name, detail: `${r.count.toLocaleString()} of ${r.total.toLocaleString()}` }));
    }
    get dataQualityError() {
        return this.error('dataQuality');
    }

    get staleDataError() {
        return this.error('staleData');
    }

    get licensesError() {
        return this.error('licenses');
    }

    get legacyList() {
        const d = this.data('automation');
        if (!d) return [];
        return d.legacyProcesses.slice(0, LIST_LIMIT).map((p) => ({
            key: p.apiName,
            name: p.name,
            detail: 'Process Builder · last changed ' + fmtDate(p.lastModified)
        }));
    }
    get legacyMore() {
        const n = this.legacyCount - this.legacyList.length;
        return n > 0 ? `and ${n} more` : '';
    }
    get multiTriggerList() {
        const d = this.data('automation');
        if (!d) return [];
        return d.multiTriggerObjects.map((m, i) => ({
            key: 'trigger-' + i,
            name: m.object,
            detail: m.triggers.length + ' triggers: ' + m.triggers.join(', ')
        }));
    }
    get automationSummary() {
        const d = this.data('automation');
        if (!d) return '';
        const stuck = d.stuckFlowCount === null ? '' : ` ${d.stuckFlowCount} flows paused for over 30 days.`;
        return `${d.apexClassCount} Apex classes, ${d.oldClassCount} of them on API versions older than 45. ${d.activeTriggers} active triggers. ${d.oldFlowCount} flows on old API versions.${stuck}`;
    }
    get automationError() {
        return this.error('automation');
    }

    get leadSources() {
        const d = this.data('leadFlow');
        if (!d || d.skipped) return [];
        const order = { quiet: 0, dropping: 1, ok: 2 };
        return [...d.sources]
            .sort((a, b) => order[a.status] - order[b.status] || b.last60 - a.last60)
            .slice(0, 15)
            .map((s) => ({
                key: s.source,
                name: s.source,
                detail: `${s.perDay} per day on average · ${s.last7} in the last 7 days · last lead ${fmtHours(s.hoursSinceLast)}`,
                pill: s.status === 'quiet' ? 'Gone quiet' : s.status === 'dropping' ? 'Dropping' : 'Normal',
                pillCls: 'pill ' + (s.status === 'quiet' ? 'bad' : s.status === 'dropping' ? 'warn' : 'good')
            }));
    }
    get hasLeadSources() {
        return this.leadSources.length > 0;
    }
    get leadFlowHint() {
        const d = this.data('leadFlow');
        return d && d.skipped ? 'Leads are not available for this user.' : 'No leads were created in the last 60 days.';
    }
    get leadFlowError() {
        return this.error('leadFlow');
    }

    get adminUsers() {
        const d = this.data('access');
        if (!d) return [];
        return d.modifyAllUsers.slice(0, LIST_LIMIT).map((u) => ({
            key: u.id,
            name: u.name,
            detail: u.via.join(' · ')
        }));
    }
    get accessSummary() {
        const d = this.data('access');
        if (!d) return '';
        return `${d.modifyAllCount} of ${d.activeUsers} active users can modify all data, and ${d.viewAllCount} can view all data.`;
    }
    get accessError() {
        return this.error('access');
    }

    get dupRows() {
        const d = this.data('duplicates');
        if (!d) return [];
        return Object.keys(d.activeRules).map((k) => ({
            key: k,
            name: k,
            pill: d.activeRules[k] > 0 ? d.activeRules[k] + ' active' : 'No active rule',
            pillCls: 'pill ' + (d.activeRules[k] > 0 ? 'good' : 'warn')
        }));
    }
    get duplicatesError() {
        return this.error('duplicates');
    }

    get fieldGroups() {
        return this.scanObjects.map((o) => {
            const key = 'fields:' + o;
            const d = this.data(key);
            const err = this.error(key);
            if (err) {
                return { key, title: o, error: err, rows: [], summary: '' };
            }
            if (!d || d.skipped) {
                return { key, title: o, error: null, rows: [], summary: 'Not available for this user.' };
            }
            if (d.sampleSize < 20) {
                return {
                    key,
                    title: d.label,
                    error: null,
                    rows: [],
                    summary: `Only ${d.sampleSize} records, too few to judge.`
                };
            }
            return {
                key,
                title: d.label,
                error: null,
                summary: `${d.rarelyUsedCount} of ${d.scannedFieldCount} custom fields are filled in under 5% of the latest ${d.sampleSize} records (${d.neverUsedCount} never).${
                    d.tooNewCount > 0
                        ? ` ${d.tooNewCount} changed in the last ${d.minAgeDays} days were skipped as too new to judge.`
                        : ''
                }`,
                rows: d.rarelyUsed.slice(0, 8).map((f) => ({
                    key: f.apiName,
                    name: f.label,
                    detail: f.apiName + (f.isCheckbox ? ' · checkbox, ticked ' : ' · filled ') + f.filledPct + '%'
                }))
            };
        });
    }

    // ---------------- actions ----------------
    get pdfUrl() {
        const params = new URLSearchParams({
            score: this.score,
            tier: this.tier.name,
            waste: this.isSandbox ? '' : money(this.yearlyWaste),
            fix: JSON.stringify(this.fixFirst.map((f) => ({ title: f.title, effort: f.effort, how: f.how }))),
            ...this.scanParams
        });
        return '/apex/OrgXRayReport?' + params.toString();
    }
    get scanParams() {
        return { sample: SAMPLE_SIZE, minAge: MIN_FIELD_AGE_DAYS, objects: this.scanObjects.join(',') };
    }
    get usersCsvUrl() {
        return '/apex/OrgXRayExport?' + new URLSearchParams({ type: 'users' }).toString();
    }
    get fieldsCsvUrl() {
        return '/apex/OrgXRayExport?' + new URLSearchParams({ type: 'fields', ...this.scanParams }).toString();
    }
}
