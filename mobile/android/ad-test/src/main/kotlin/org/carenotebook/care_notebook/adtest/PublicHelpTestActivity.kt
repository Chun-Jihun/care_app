package org.carenotebook.care_notebook.adtest

import android.app.Activity
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.google.ads.mediation.admob.AdMobAdapter
import com.google.android.gms.ads.AdListener
import com.google.android.gms.ads.AdRequest
import com.google.android.gms.ads.AdSize
import com.google.android.gms.ads.AdView
import com.google.android.gms.ads.LoadAdError
import com.google.android.gms.ads.MobileAds

/** Test-only public content. The launcher supplies no arguments or notebook state. */
class PublicHelpTestActivity : Activity() {
    private var banner: AdView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        setContentView(ScrollView(this).apply { addView(content) })

        fun paragraph(copy: String, heading: Boolean = false) {
            content.addView(TextView(this).apply {
                text = copy
                textSize = if (heading) 20f else 16f
                setPadding(dp(20), dp(if (heading) 20 else 4), dp(20), dp(12))
                if (android.os.Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = heading
            })
        }

        paragraph("진료 전에 준비하기", true)
        paragraph("진료 탭에서 물어볼 질문을 적고 의료진에게 보여줄 기록을 고르세요. 진료가 끝난 뒤 들은 설명과 다음 할 일은 진료·연락 기록에 남길 수 있어요.")
        paragraph("기기를 바꾸기 전에", true)
        paragraph("설정의 선택 백업에서 옮길 수첩과 기간을 고르세요. 백업 비밀번호는 파일과 다른 곳에 보관하세요. 작성 중인 초안과 진료 녹음 원본은 백업에서 제외돼요.")
        paragraph("읽기 편하게 바꾸기", true)
        paragraph("설정의 화면·접근성에서 큰 글자, 큰 버튼, 고대비를 켤 수 있어요. 홈 화면 편집에서 자주 쓰는 항목을 위에 두세요.")
        paragraph("광고 시험", true)
        paragraph("시험 배너를 요청하면 Google에 IP 주소와 기기 정보 등이 전송될 수 있어요. 이 화면에서는 수첩이나 녹음 정보를 요청에 담지 않아요. 배너를 불러오지 않아도 안내를 읽을 수 있어요.")
        content.addView(Button(this).apply {
            text = "시험 배너 불러오기"
            setOnClickListener {
                if (content.width < dp(320)) {
                    text = "이 화면 너비에서는 배너를 표시할 수 없어요."
                    isEnabled = false
                } else {
                    isEnabled = false
                    loadBanner(content, this)
                }
            }
        })
    }

    private fun loadBanner(content: LinearLayout, button: Button) {
        MobileAds.disableMediationAdapterInitialization(this)
        MobileAds.putPublisherFirstPartyIdEnabled(false)
        val view = AdView(this).apply {
            adUnitId = "ca-app-pub-3940256099942544/6300978111"
            setAdSize(AdSize.BANNER)
            visibility = View.GONE
        }
        banner = view
        content.addView(view, LinearLayout.LayoutParams(-2, -2).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            topMargin = dp(12)
            bottomMargin = dp(24)
        })
        view.adListener = object : AdListener() {
            override fun onAdLoaded() {
                if (banner !== view) return
                button.visibility = View.GONE
                view.visibility = View.VISIBLE
            }

            override fun onAdFailedToLoad(adError: LoadAdError) {
                if (banner !== view) return
                content.removeView(view)
                view.destroy()
                banner = null
                button.text = "시험 배너를 불러오지 못했어요."
            }
        }
        val extras = Bundle().apply { putString("npa", "1") }
        view.loadAd(AdRequest.Builder().addNetworkExtrasBundle(AdMobAdapter::class.java, extras).build())
    }

    override fun onPause() {
        banner?.pause()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        banner?.resume()
    }

    override fun onDestroy() {
        val view = banner
        banner = null
        view?.destroy()
        super.onDestroy()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
