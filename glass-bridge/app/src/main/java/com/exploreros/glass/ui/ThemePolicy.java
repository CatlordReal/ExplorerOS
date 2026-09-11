package com.exploreros.glass.ui;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.res.Configuration;
import java.util.Calendar;

/** Compact API19 theme policy with all Explorer semantic palettes and manual/scheduled choices. */
public final class ThemePolicy {
    private static final String[] PALETTES = { "Latte", "Frappé", "Macchiato", "Mocha", "Sand", "Dawn Paper", "Golden Sand", "Golden Paper", "Sunset", "Dusk", "Light", "Dark", "System", "Time", "Sunrise", "Golden Hour", "Sunset schedule", "Dusk schedule" }; private static final int[][] COLORS = { {0xffeff1f5,0xff1e1e2e},{0xff303446,0xffc6d0f5},{0xff24273a,0xffcad3f5},{0xff1e1e2e,0xffcdd6f4},{0xfffff5dc,0xff302b1c},{0xfffffbf2,0xff493b2b},{0xffffe8a6,0xff342500},{0xfffff2cc,0xff463500},{0xff3a1f24,0xffffd8c2},{0xff17151f,0xffe5d9ff} };
    private ThemePolicy() { }
    public static void next(Context context) { SharedPreferences p = context.getSharedPreferences("theme", Context.MODE_PRIVATE); p.edit().putInt("choice", (p.getInt("choice", 3) + 1) % PALETTES.length).commit(); }
    public static int[] colors(Context context) { int choice = context.getSharedPreferences("theme", Context.MODE_PRIVATE).getInt("choice", 3); if (choice == 10) return COLORS[0]; if (choice == 11) return COLORS[3]; if (choice == 12) return (context.getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES ? COLORS[3] : COLORS[0]; if (choice >= 13) choice = scheduled(choice, Calendar.getInstance().get(Calendar.HOUR_OF_DAY)); return COLORS[choice % 10]; }
    public static String label(Context context) { return PALETTES[context.getSharedPreferences("theme", Context.MODE_PRIVATE).getInt("choice", 3)]; }
    private static int scheduled(int mode, int hour) { if (mode == 14) return hour < 7 ? 9 : 4; if (mode == 15) return hour >= 17 && hour <= 19 ? 6 : (hour < 7 ? 9 : 4); if (mode == 16) return hour >= 19 ? 8 : 4; return hour >= 20 || hour < 6 ? 9 : 4; }
}
