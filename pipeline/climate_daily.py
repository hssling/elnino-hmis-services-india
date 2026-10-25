"""Grid-level daily → monthly climate functions."""
import calendar
import warnings
from datetime import date

import numpy as np

RAINY_DAY_MM = 2.5


def _ndays(year):
    return 366 if calendar.isleap(year) else 365


def month_index(year) -> np.ndarray:
    return np.array([date.fromordinal(date(year, 1, 1).toordinal() + k).month - 1 for k in range(_ndays(year))])


def doy366_index(year) -> np.ndarray:
    idx = np.arange(366)
    return idx if calendar.isleap(year) else np.delete(idx, 59)


def daily_to_monthly(daily, year, how="sum") -> np.ndarray:
    mi = month_index(year)
    out = np.empty((12,) + daily.shape[1:], dtype=float)
    for m in range(12):
        chunk = daily[mi == m]
        if how == "sum":
            s = np.nansum(chunk, axis=0)
            s[np.all(np.isnan(chunk), axis=0)] = np.nan
            out[m] = s
        else:
            with warnings.catch_warnings():  # all-NaN (ocean) cells -> NaN is intended
                warnings.simplefilter("ignore", RuntimeWarning)
                out[m] = np.nanmean(chunk, axis=0)
    return out


def monthly_counts(mask, year) -> np.ndarray:
    mi = month_index(year)
    return np.stack([mask[mi == m].sum(axis=0) for m in range(12)])


def tmax_climatology(tmax_by_year: dict, window=31) -> np.ndarray:
    first = next(iter(tmax_by_year.values()))
    total = np.zeros((366,) + first.shape[1:])
    count = np.zeros_like(total)
    for y, a in tmax_by_year.items():
        idx = doy366_index(y)
        ok = ~np.isnan(a)
        total[idx] += np.where(ok, a, 0.0)
        count[idx] += ok
    with np.errstate(all="ignore"):
        mean = total / count
    # Feb 29 only in leap years: fill gaps by neighbour before smoothing
    mean[59] = np.where(np.isnan(mean[59]), (mean[58] + mean[60]) / 2, mean[59])
    half = window // 2
    padded = np.concatenate([mean[-half:], mean, mean[:half]])
    kernel_sum = np.cumsum(np.nan_to_num(padded), axis=0)
    kernel_cnt = np.cumsum(~np.isnan(padded), axis=0)
    s = kernel_sum[window - 1:] - np.concatenate([np.zeros((1,) + mean.shape[1:]), kernel_sum[:-window]])
    c = kernel_cnt[window - 1:] - np.concatenate([np.zeros((1,) + mean.shape[1:]), kernel_cnt[:-window]])
    with np.errstate(all="ignore"):
        return (s / c)[:366]


def heatwave_mask(tmax, year, clim) -> np.ndarray:
    c = clim[doy366_index(year)]
    with np.errstate(invalid="ignore"):
        return (tmax >= 45) | ((tmax >= 40) & (tmax - c >= 4.5))


def onset_doy(rain_daily, year) -> float:
    start = date(year, 5, 1).timetuple().tm_yday - 1
    last = date(year, 9, 30).timetuple().tm_yday - 1
    r = np.nan_to_num(np.asarray(rain_daily, dtype=float))
    for d in range(start, last + 1):
        if r[d:d + 5].sum() < 25:
            continue
        dry = any(r[s:s + 7].sum() < 5 for s in range(d + 5, d + 14) if s + 7 <= len(r))
        if not dry:
            return float(d + 1)
    return float("nan")
