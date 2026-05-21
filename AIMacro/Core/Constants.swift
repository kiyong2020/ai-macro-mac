//
//  Constants.swift
//  AIMacro
//
//  Created by Kiyong Kim on 7/8/25.
//
import Foundation

class Constants {
    /// Side length (logical points) of the square OCR capture region
    /// centered on the action point. Used by both the actual OCR capture
    /// and the on-screen position-picker preview.
    static let ocrCaptureSize: CGFloat = 200

    /// When false, the floating OCR debug window (live captured frame +
    /// recognised text list) is suppressed for both the position picker and
    /// macro execution. Useful for production runs where the debug overlay
    /// would just be visual noise.
    static let showOCRDebugWindow: Bool = false

    /// Shape-weighted similarity threshold required for an OCR match to be
    /// clicked. 1.0 is a perfect match; ~0.75 covers single-jamo OCR misreads
    /// while keeping unrelated text below the bar.
    static let ocrMatchThreshold: Double = 0.75

    static let devServerURL = "http://mini.minseye.co.kr:3021"
    static let debugServerURL = "http://192.168.0.117:3021"

    /// Base URL of the ai-macro-api server. The `.aiGen` action POSTs to
    /// `<baseServerURL>/generate-actions` to translate a captured screen
    /// region + instruction into a list of `AutoAction`s.
    /// Mutable: chosen at launch via the server-selection popup in AppDelegate.
    static var baseServerURL = devServerURL

//     static let test : [AutoAction] = [
//         .init(type: .click, group: "seonam", name: "화면클릭", point: .zero, delay: 0.01),
//         .init(type: .windowFrame, group: "seonam", name: "크기저장", point: .zero, delay: 1),
//         .init(type: .ocr, group: "seonam", name: "버튼1", point: .zero, delay: 0.7, text: "예약하기"),
//         .init(type: .ocr, group: "seonam", name: "버튼2", point: .zero, delay: 0.7, text: "예약하기"),
//     ]

//     static let seonam : [AutoAction] = [
// //        .init(type: .windowFrame, group: "seonam", name: "크기저장", point: .zero, delay: 2),
//         .init(type: .click, group: "seonam", name: "팝업닫기", point: .zero, delay: 0.8),
//         .init(type: .click, group: "seonam", name: "일자", point: .zero, delay: 0.2),
//         .init(type: .click, group: "seonam", name: "회차", point: .zero, delay: 0.01),
//         .init(type: .key, group: "seonam", name: "스크롤1(space)", delay: 0.4, count: 1, text: ":space"),
//         .init(type: .click, group: "seonam", name: "인원", point: .zero, delay: 0.1, count:3),
//         .init(type: .click, group: "seonam", name: "배경2", point: .zero, delay: 0.01),
//         .init(type: .key, group: "seonam", name: "스크롤2(space)", delay: 0.4, count: 1, text: ":space"),
//         .init(type: .click, group: "seonam", name: "인증번호발송", point: .zero, delay: 1),
//         .init(type: .key, group: "seonam", name: "팝업1", delay: 0.2, text: ":enter"),
//         .init(type: .click, group: "seonam", name: "인증번호입력", point: .zero, delay: 0.01, count: 2),
//         .init(type: .click, group: "seonam", name: "인증확인", point: .zero, delay: 0.1),
//          .init(type: .key, group: "seonam", name: "스크롤3(space)", delay: 0.4, count: 3, text: ":space"),
//         .init(type: .click, group: "seonam", name: "전체동의", point: .zero, delay: 0.1),
//         .init(type: .wait(type: .click), group: "seonam", name: "예약하기대기", delay: 0.3),
//         .init(type: .key, group: "seonam", name: "팝업2", delay: 0.2, text: ":enter"),
//         .init(type: .key, group: "seonam", name: "팝업3", delay: 0.2, text: ":enter"),
//         .init(type: .key, group: "seonam", name: "팝업4", delay: 0.2, text: ":enter"),
//         .init(type: .key, group: "seonam", name: "팝업5", delay: 0.2, text: ":enter"),    ]

//     static let seonamOld : [AutoAction] = [
//         .init(type: .click, group: "seonam", name: "팝업닫기", point: .zero, delay: 0.8),
//         .init(type: .click, group: "seonam", name: "일자", point: .zero, delay: 0.2),
//         .init(type: .click, group: "seonam", name: "회차", point: .zero, delay: 0.01),
//         .init(type: .key, group: "seonam", name: "스크롤1(space)", delay: 0.4, count: 1, text: ":space"),
//         .init(type: .click, group: "seonam", name: "인원", point: .zero, delay: 0.1, count:3),
//         .init(type: .click, group: "seonam", name: "배경2", point: .zero, delay: 0.01),
//         .init(type: .key, group: "seonam", name: "스크롤2(space)", delay: 0.4, count: 1, text: ":space"),
//         .init(type: .click, group: "seonam", name: "인증번호발송", point: .zero, delay: 1),
//         .init(type: .key, group: "seonam", name: "팝업1", delay: 0.2, text: ":enter"),
//         .init(type: .click, group: "seonam", name: "인증번호입력", point: .zero, delay: 0.01, count: 2),
//         .init(type: .click, group: "seonam", name: "인증확인", point: .zero, delay: 0.1),
//          .init(type: .key, group: "seonam", name: "스크롤3(space)", delay: 0.4, count: 3, text: ":space"),
//         .init(type: .click, group: "seonam", name: "전체동의", point: .zero, delay: 0.1),
// //        .init(type: .ocr, group: "seonam", name: "예약하기2", point: .zero, delay: 0.7, text: "예약하기"),
//         .init(type: .wait(type: .click), group: "seonam", name: "예약하기대기", delay: 0.3),
//         .init(type: .key, group: "seonam", name: "팝업2", delay: 0.2, text: ":enter"),
//         .init(type: .key, group: "seonam", name: "팝업3", delay: 0.2, text: ":enter"),
//         .init(type: .key, group: "seonam", name: "팝업4", delay: 0.2, text: ":enter"),
//         .init(type: .key, group: "seonam", name: "팝업5", delay: 0.2, text: ":enter"),
//     ]

//     /// 서남 완전 자동
//     static let seonamFull : [AutoAction] = [
//         .init(type: .openChrome(url: "https://yeyak.seoul.go.kr/web/main.do"), group: "seonam", name: "창열기", point: .zero, delay: 2),
//         .init(type: .windowFrame, group: "seonam", name: "크기저장", point: .zero, delay: 2),
//         .init(type: .click, group: "seonam", name: "로그인클릭", point: .zero, delay: 2),
//         .init(type: .click, group: "seonam", name: "카카오로그인", point: .zero, delay: 2),
//         .init(type: .click, group: "seonam", name: "계정선택/배경", point: .zero, delay: 2),
// //       .init(type: .setURL(url: "https://kauth.kakao.com/oauth/authorize?client_id=1b78b76d69fbf854ae4017ba98d18122&redirect_uri=https://yeyak.seoul.go.kr/web/kakaoLogin.do&response_type=code&state=1"), group: "seonam", name: "로그인", point: .zero, delay: 1),
//         .init(type: .setURL(url: "https://yeyak.seoul.go.kr/web/reservation/selectReservView.do?rsv_svc_id=S230131090246367142"), group: "seonam", name: "예약화면", point: .zero, delay: 1),
//         .init(type: .click, group: "seonam", name: "팝업닫기1", point: .zero, delay: 2),
//         .init(type: .click, group: "seonam", name: "예약하기1", point: .zero, delay: 2),
//         .init(type: .click, group: "seonam", name: "달력조정", point: .zero, delay: 2),
//         .init(type: .wait(type: .time), group: "seonam", name: "시간대기", point: .zero, delay: 0.8),
//         .init(type: .click, group: "seonam", name: "팝업닫기2", point: .zero, delay: 0.8),
//         .init(type: .click, group: "seonam", name: "일자", point: .zero, delay: 0.2),
//         .init(type: .click, group: "seonam", name: "회차", point: .zero, delay: 0.01),
//         .init(type: .key, group: "seonam", name: "스크롤1(space)", delay: 0.4, count: 1, text: ":space"),
//         .init(type: .click, group: "seonam", name: "인원", point: .zero, delay: 0.1, count:3),
//         .init(type: .click, group: "seonam", name: "배경1", point: .zero, delay: 0.01),
//         .init(type: .key, group: "seonam", name: "스크롤2(space)", delay: 0.4, count: 1, text: ":space"),
//         .init(type: .click, group: "seonam", name: "인증번호발송", point: .zero, delay: 1),
//         .init(type: .key, group: "seonam", name: "팝업1", delay: 0.2, text: ":enter"),
//         .init(type: .click, group: "seonam", name: "인증번호입력", point: .zero, delay: 0.01, count: 2),
//         .init(type: .click, group: "seonam", name: "인증확인", point: .zero, delay: 0.1),
//         .init(type: .click, group: "seonam", name: "배경2", point: .zero, delay: 0.01),
//         .init(type: .key, group: "seonam", name: "스크롤3(space)", delay: 0.4, count: 3, text: ":space"),
//         .init(type: .click, group: "seonam", name: "전체동의", point: .zero, delay: 0.1),
//         .init(type: .ocr, group: "seonam", name: "예약하기버튼", point: .zero, delay: 0.7, text: "예약하기"),
//         .init(type: .click, group: "seonam", name: "팝업닫기3", point: .zero, delay: 0.01),
// //        .init(type: .key, group: "seonam", name: "팝업2", delay: 0.2, text: ":enter"),
// //        .init(type: .key, group: "seonam", name: "팝업3", delay: 0.2, text: ":enter"),
// //        .init(type: .key, group: "seonam", name: "팝업4", delay: 0.2, text: ":enter"),
// //        .init(type: .key, group: "seonam", name: "팝업5", delay: 0.2, text: ":enter"),
//     ]

//     static let sangam : [AutoAction] = [
//         .init(type: .wait(type: .enter), group: "sangam", name: "엔터키대기"),
//         .init(type: .click, group: "sangam", name: "이용권 배경", point: .zero, delay: 0.01),
//         .init(type: .scroll, group: "seonam", name: "스크롤1(space)", delay: 0.2, count: 1),
//         .init(type: .click, group: "sangam", name: "인원", point: .zero, delay: 0.01, count: 4),
//         .init(type: .click, group: "sangam", name: "예매하기2", point: .zero, delay: 0.1),
//     ]
    
//     static let yangchun : [AutoAction] = [
//         .init(type: .script(code: Constants.yangchunScript), group: "yangchun", name: "스크립트", delay: 0.2, count: 1, text:"2025-07-20"),

//     ]

//     static let yangchunURL = "https://www.yangcheon.go.kr/reservation/reservation/foffice/ex/reservationCal/userForm.do?year=2025&${TEXT}&pageIndex=1&riIdx=RI001677&tab=R&timeweek=&restAt="
// //    static let yangchunScript = """
// //            alert('hello');
// //        """;
//     static let yangchunScript = """
// window.doReservationCalUserInfoReg = () =>{
//   $("#stfacTime").val("1");
//   $("#ruReservationDay").val('${TEXT}');
//     if ($("#ruName").val() == '') {
//         alert("이름을 입력해주십시오.");
//         $("#ruName").focus();
//         return false;
//     }
//     if ($("#ruZipcode").val() == '') {
//         alert("주소를 입력해주십시오.");
//         $("#ruZipcode").focus();
//         return false;
//     }

//     $("#ruHp").val("01044998563");

//   $("#dong").val("기타");

//     $("#ReservationUserInfoVo").attr("target", "_self");

//   if (doReservationCalConAx()) {
//     $("#ReservationUserInfoVo").attr("action", "/reservation/reservation/foffice/ex/reservationCal/userReg.do").submit();
//   } else {
//     alert('fail');
//     return false;
//   }
// }

// doReservationCalUserInfoReg();
// """



}
