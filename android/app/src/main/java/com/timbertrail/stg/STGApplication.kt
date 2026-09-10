package com.timbertrail.stg

import android.app.Application
import android.content.Context

class STGApplication : Application() {
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(LanguageSupport.wrap(base))
    }
}
