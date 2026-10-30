from pathlib import Path
import subprocess
import unittest

AWK = Path(__file__).resolve().parents[1] / 'router/usage-state.awk'
BASE = 1793289600  # A fixed reference is enough; explicit midnight is supplied.


def update(old='', *, day='2026-10-30', now=BASE+60, midnight=BASE, used=1000, total=10000, fingerprint='same'):
    args=['awk']
    for key,value in locals().copy().items():
        if key not in ('old','args'):
            args += ['-v', f'{key}={value}']
    args += ['-v', 'expire=0', '-f', str(AWK)]
    line=subprocess.run(args,input=old,text=True,capture_output=True,check=True).stdout
    return line, line.strip().split('\t')


class DailyUsageTests(unittest.TestCase):
    def test_first_install_is_partial_and_not_a_fabricated_full_day(self):
        _, row=update()
        self.assertEqual(row[4:7], ['0','1','0'])

    def test_same_day_uses_provider_delta(self):
        old,_=update()
        _, row=update(old,now=BASE+360,used=1450)
        self.assertEqual(row[4], '450')

    def test_midnight_starts_a_new_observed_day(self):
        old=f'2026-10-29\t{BASE-3600}\t{BASE-90}\t900\t800\t1\t0\tsame\t10000\t0\n'
        _,row=update(old)
        self.assertEqual(row[4:7], ['0','0','0'])

    def test_offline_over_midnight_stays_partial(self):
        old=f'2026-10-29\t{BASE-7200}\t{BASE-3600}\t900\t800\t0\t0\tsame\t10000\t0\n'
        _,row=update(old,now=BASE+3600)
        self.assertEqual(row[5], '1')

    def test_counter_reset_is_marked_and_never_negative(self):
        old,_=update(used=1000)
        old,_=update(old,used=1500,now=BASE+360)
        _,row=update(old,used=50,now=BASE+660)
        self.assertEqual(row[4:7], ['550','1','1'])

    def test_new_subscription_does_not_inherit_old_usage(self):
        old,_=update()
        _,row=update(old,used=9999,fingerprint='different')
        self.assertEqual(row[4:7], ['0','1','0'])


if __name__ == '__main__':
    unittest.main()
