"""Unit tests for the new billing infrastructure modules."""

import os
import tempfile
import time
import unittest

from metrix import billing, exporter, retry, validators
from metrix.cache import TTLCache
from metrix.config import Config
from metrix.eventbuffer import EventBuffer
from metrix.metrics_registry import MetricsRegistry
from metrix.scheduler import Scheduler


class TestBilling(unittest.TestCase):
    def test_total_usage_sums_all_events(self):
        events = [{"amount": 1.5}, {"amount": 2.5}, {"amount": 1.0}]
        self.assertEqual(billing.total_usage(events), 5.0)

    def test_total_usage_empty(self):
        self.assertEqual(billing.total_usage([]), 0.0)

    def test_page_count_exact_multiple(self):
        self.assertEqual(billing.page_count(100), 2)

    def test_page_count_partial_page(self):
        self.assertEqual(billing.page_count(101), 3)

    def test_page_count_zero(self):
        self.assertEqual(billing.page_count(0), 0)

    def test_average_latency_ms(self):
        self.assertEqual(billing.average_latency_ms([10, 20, 30]), 20.0)

    def test_average_latency_ms_empty(self):
        self.assertEqual(billing.average_latency_ms([]), 0.0)

    def test_amount_to_cents_rounds(self):
        self.assertEqual(billing.amount_to_cents(19.995), 2000)

    def test_summarize_known_kind(self):
        events = [{"kind": "api_call", "amount": 1.0}]
        summary = billing.summarize(events)
        self.assertEqual(summary["api_call"], 2)

    def test_summarize_unknown_kind_skipped(self):
        events = [{"kind": "mystery", "amount": 1.0}]
        summary = billing.summarize(events)
        self.assertEqual(summary, {})


class TestCache(unittest.TestCase):
    def test_set_and_get(self):
        cache = TTLCache(ttl_seconds=60)
        cache.set("k", "v")
        self.assertEqual(cache.get("k"), "v")

    def test_get_missing_returns_none(self):
        cache = TTLCache(ttl_seconds=60)
        self.assertIsNone(cache.get("missing"))

    def test_expired_entry_returns_none(self):
        cache = TTLCache(ttl_seconds=0)
        cache.set("k", "v")
        time.sleep(0.01)
        self.assertIsNone(cache.get("k"))

    def test_get_or_load_calls_loader_once(self):
        cache = TTLCache(ttl_seconds=60)
        calls = []

        def loader(key):
            calls.append(key)
            return "loaded-" + key

        self.assertEqual(cache.get_or_load("k", loader), "loaded-k")
        self.assertEqual(cache.get_or_load("k", loader), "loaded-k")
        self.assertEqual(calls, ["k"])

    def test_invalidate(self):
        cache = TTLCache(ttl_seconds=60)
        cache.set("k", "v")
        cache.invalidate("k")
        self.assertIsNone(cache.get("k"))

    def test_clear(self):
        cache = TTLCache(ttl_seconds=60)
        cache.set("a", 1)
        cache.set("b", 2)
        cache.clear()
        self.assertEqual(cache.size(), 0)

    def test_size(self):
        cache = TTLCache(ttl_seconds=60)
        cache.set("a", 1)
        cache.set("b", 2)
        self.assertEqual(cache.size(), 2)


class TestEventBuffer(unittest.TestCase):
    def test_push_and_drain(self):
        buf = EventBuffer()
        buf.push({"tenant": "acme"})
        self.assertEqual(len(buf), 1)
        drained = buf.drain()
        self.assertEqual(len(drained), 1)
        self.assertEqual(len(buf), 0)

    def test_drain_preserves_order(self):
        buf = EventBuffer()
        for i in range(5):
            buf.push({"n": i})
        drained = buf.drain()
        self.assertEqual([e["n"] for e in drained], [0, 1, 2, 3, 4])

    def test_drain_empty(self):
        buf = EventBuffer()
        self.assertEqual(buf.drain(), [])

    def test_respects_max_size(self):
        buf = EventBuffer(max_size=2)
        buf.push({"n": 1})
        buf.push({"n": 2})
        buf.push({"n": 3})
        self.assertEqual(len(buf), 2)


class TestScheduler(unittest.TestCase):
    def test_tick_runs_due_job(self):
        calls = []
        jobs = [{"name": "x", "func": "do_x", "interval": 0}]
        sched = Scheduler(jobs=jobs, clock=lambda: 100.0, sleep=lambda s: None)
        sched.tick({"do_x": lambda: calls.append("ran")})
        self.assertEqual(calls, ["ran"])

    def test_tick_skips_job_not_yet_due(self):
        calls = []
        jobs = [{"name": "x", "func": "do_x", "interval": 1000}]
        clock = {"t": 0.0}
        sched = Scheduler(jobs=jobs, clock=lambda: clock["t"], sleep=lambda s: None)
        sched.tick({"do_x": lambda: calls.append("ran")})
        clock["t"] = 1.0
        sched.tick({"do_x": lambda: calls.append("ran")})
        self.assertEqual(calls, ["ran"])

    def test_tick_runs_job_again_after_interval(self):
        calls = []
        jobs = [{"name": "x", "func": "do_x", "interval": 10}]
        clock = {"t": 0.0}
        sched = Scheduler(jobs=jobs, clock=lambda: clock["t"], sleep=lambda s: None)
        sched.tick({"do_x": lambda: calls.append("ran")})
        clock["t"] = 11.0
        sched.tick({"do_x": lambda: calls.append("ran")})
        self.assertEqual(calls, ["ran", "ran"])


class TestSchedulerRuntime(unittest.TestCase):
    def test_register_adds_job(self):
        sched = Scheduler(jobs=[], clock=lambda: 0.0, sleep=lambda s: None)
        sched.register("new-job", "do_new", 10)
        self.assertEqual(sched.next_due_in("new-job"), 10)

    def test_unregister_removes_job(self):
        jobs = [{"name": "x", "func": "do_x", "interval": 10}]
        sched = Scheduler(jobs=jobs, clock=lambda: 0.0, sleep=lambda s: None)
        sched.unregister("x")
        self.assertIsNone(sched.next_due_in("x"))

    def test_next_due_in_unknown_job(self):
        sched = Scheduler(jobs=[], clock=lambda: 0.0, sleep=lambda s: None)
        self.assertIsNone(sched.next_due_in("nope"))

    def test_next_due_in_counts_down(self):
        jobs = [{"name": "x", "func": "do_x", "interval": 10}]
        clock = {"t": 0.0}
        sched = Scheduler(jobs=jobs, clock=lambda: clock["t"], sleep=lambda s: None)
        sched.tick({"do_x": lambda: None})
        clock["t"] = 4.0
        self.assertEqual(sched.next_due_in("x"), 6.0)


class TestNotifications(unittest.TestCase):
    def test_notify_invoice_ready_builds_expected_event(self):
        from metrix import notifications

        sent = []
        notifications._post = lambda url, payload: sent.append(payload)
        notifications.notify_invoice_ready("https://hooks.example/x", "acme", "inv-1")
        self.assertEqual(sent[0]["event"], "invoice_ready")
        self.assertEqual(sent[0]["tenant"], "acme")

    def test_notify_returns_false_after_exhausting_retries(self):
        from metrix import notifications

        def always_fails(url, payload):
            raise ConnectionError("down")

        notifications._post = always_fails
        result = notifications.notify("https://hooks.example/x", "invoice_ready", "acme", {})
        self.assertFalse(result)

    def test_notify_batch_reports_failed_tenants(self):
        from metrix import notifications

        def fails_for_b(url, payload):
            if payload["tenant"] == "b":
                raise ConnectionError("down")

        notifications._post = fails_for_b
        failed = notifications.notify_batch(
            "https://hooks.example/x",
            [("invoice_ready", "a", {}), ("invoice_ready", "b", {})],
        )
        self.assertEqual(failed, ["b"])

    def test_build_digest_lists_each_tenant(self):
        from metrix import notifications

        digest = notifications.build_digest({"acme": [1, 2], "beta": [1]})
        self.assertIn("acme: 2 event(s)", digest)
        self.assertIn("beta: 1 event(s)", digest)


class TestRetry(unittest.TestCase):
    def test_retry_returns_value_on_success(self):
        @retry.retry(max_attempts=3, base_delay=0)
        def ok():
            return 42

        self.assertEqual(ok(), 42)

    def test_retry_reraises_after_max_attempts(self):
        calls = []

        @retry.retry(max_attempts=2, base_delay=0)
        def always_fails():
            calls.append(1)
            raise ValueError("nope")

        with self.assertRaises(ValueError):
            always_fails()
        self.assertEqual(len(calls), 2)

    def test_retry_succeeds_after_transient_failure(self):
        attempts = {"n": 0}

        @retry.retry(max_attempts=3, base_delay=0)
        def flaky():
            attempts["n"] += 1
            if attempts["n"] < 2:
                raise ValueError("try again")
            return "ok"

        self.assertEqual(flaky(), "ok")


class TestMetricsRegistry(unittest.TestCase):
    def test_increment_default(self):
        reg = MetricsRegistry()
        reg.increment("hits")
        reg.increment("hits")
        self.assertEqual(reg.snapshot()["hits"], 2)

    def test_increment_by_amount(self):
        reg = MetricsRegistry()
        reg.increment("bytes", amount=100)
        self.assertEqual(reg.snapshot()["bytes"], 100)

    def test_set_gauge(self):
        reg = MetricsRegistry()
        reg.set_gauge("queue_depth", 7)
        self.assertEqual(reg.snapshot()["queue_depth"], 7)

    def test_reset(self):
        reg = MetricsRegistry()
        reg.increment("hits")
        reg.set_gauge("g", 1)
        reg.reset()
        self.assertEqual(reg.snapshot(), {})


class TestValidators(unittest.TestCase):
    def test_valid_tenant_id(self):
        self.assertTrue(validators.validate_tenant_id("acme-corp"))

    def test_invalid_tenant_id_uppercase(self):
        self.assertFalse(validators.validate_tenant_id("Acme"))

    def test_invalid_tenant_id_empty(self):
        self.assertFalse(validators.validate_tenant_id(""))

    def test_valid_webhook_url(self):
        self.assertTrue(validators.validate_webhook_url("https://hooks.example/x"))

    def test_invalid_webhook_url_http(self):
        self.assertFalse(validators.validate_webhook_url("http://hooks.example/x"))

    def test_valid_email(self):
        self.assertTrue(validators.validate_email("a@b.com"))

    def test_invalid_email(self):
        self.assertFalse(validators.validate_email("not-an-email"))


class TestExporter(unittest.TestCase):
    def setUp(self):
        self._orig_export_dir = exporter.EXPORT_DIR
        self._tmpdir = tempfile.mkdtemp()
        exporter.EXPORT_DIR = self._tmpdir

    def tearDown(self):
        exporter.EXPORT_DIR = self._orig_export_dir

    def test_export_csv_writes_file(self):
        events = [{"kind": "api_call", "amount": 1.0, "created_at": "2024-01-01"}]
        path = exporter.export_csv("acme", events, "acme_export.csv")
        self.assertTrue(os.path.exists(path))

    def test_export_json_writes_file(self):
        events = [{"kind": "api_call", "amount": 1.0, "created_at": "2024-01-01"}]
        path = exporter.export_json("acme", events, "acme_export.json")
        self.assertTrue(os.path.exists(path))

    def test_list_exports_filters_by_tenant_prefix(self):
        exporter.export_csv("acme", [], "acme_a.csv")
        exporter.export_csv("other", [], "other_a.csv")
        names = exporter.list_exports("acme")
        self.assertEqual(names, ["acme_a.csv"])

    def test_delete_export_removes_file(self):
        exporter.export_csv("acme", [], "acme_a.csv")
        self.assertTrue(exporter.delete_export("acme", "acme_a.csv"))
        self.assertFalse(os.path.exists(exporter._export_path("acme", "acme_a.csv")))

    def test_delete_export_missing_returns_false(self):
        self.assertFalse(exporter.delete_export("acme", "does-not-exist.csv"))

    def test_rotate_exports_removes_old_files(self):
        path = exporter.export_csv("acme", [], "acme_old.csv")
        old_time = time.time() - (40 * 86400)
        os.utime(path, (old_time, old_time))
        removed = exporter.rotate_exports(retention_days=30)
        self.assertEqual(removed, 1)
        self.assertFalse(os.path.exists(path))

    def test_rotate_exports_keeps_recent_files(self):
        path = exporter.export_csv("acme", [], "acme_new.csv")
        removed = exporter.rotate_exports(retention_days=30)
        self.assertEqual(removed, 0)
        self.assertTrue(os.path.exists(path))


class TestConfig(unittest.TestCase):
    def test_rate_for_known_kind(self):
        cfg = Config({"rates": {"api_call": 5}})
        self.assertEqual(cfg.rate_for("api_call"), 5)

    def test_rate_for_unknown_kind_defaults_to_one(self):
        cfg = Config({"rates": {}})
        self.assertEqual(cfg.rate_for("mystery"), 1)

    def test_webhook_url_valid(self):
        cfg = Config({"webhook_url": "https://hooks.example/x"})
        self.assertEqual(cfg.webhook_url(), "https://hooks.example/x")

    def test_webhook_url_invalid_scheme_returns_none(self):
        cfg = Config({"webhook_url": "http://hooks.example/x"})
        self.assertIsNone(cfg.webhook_url())

    def test_defaults_when_missing(self):
        cfg = Config({})
        self.assertEqual(cfg.scheduler_poll_seconds(), 5)
        self.assertEqual(cfg.export_retention_days(), 30)
        self.assertEqual(cfg.max_page_size(), 200)

    def test_validate_flags_missing_rates(self):
        cfg = Config({})
        problems = cfg.validate()
        self.assertIn("missing 'rates' section", problems)

    def test_validate_passes_for_full_config(self):
        cfg = Config({"rates": {"api_call": 2}})
        self.assertEqual(cfg.validate(), [])

    def test_as_dict_is_a_copy(self):
        data = {"rates": {"api_call": 2}}
        cfg = Config(data)
        copy = cfg.as_dict()
        copy["rates"] = {}
        self.assertEqual(data["rates"], {"api_call": 2})


if __name__ == "__main__":
    unittest.main()
