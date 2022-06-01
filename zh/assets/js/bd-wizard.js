//Wizard Init

$("#wizard").steps({
    headerTag: "h3",
    bodyTag: "section",
    transitionEffect: "none",
    stepsOrientation: "vertical",
    titleTemplate: '<span class="number">#index#</span>',

    onFinished: function (event, currentIndex) { 
        var window = self.window.open("https://lomorage.com/zh/survey/", "_blank");
        window.focus();
    },

    labels: {
        finish: "完成",
        next: "下一步",
        previous: "上一步"
    }
});

var insertHtml = function (selector, argHtml) {
    $(document).ready(function(){
        $(selector).load(argHtml);
    });
};

//Form control

$(document).ready(function(){
    $('#server-install').load('windows.html');
    $('#client-install').load('android.html');
    $('#import-install').load('windows-import.html');
});

$('input:radio[name=server]').on('change', function(e) {
    if (e.target.value == "Windows") {
        insertHtml("#server-install", "windows.html");
    } else if (e.target.value == "macOS") {
        insertHtml("#server-install", "macOS.html");
    } else if (e.target.value == "others") {
        insertHtml("#server-install", "other-platforms.html");
    }
});

$('input:radio[name=client]').on('change', function(e) {
    if (e.target.value == "Android") {
        insertHtml("#client-install", "android.html");
    } else if (e.target.value == "iOS") {
        insertHtml("#client-install", "iOS.html");
    }
});

$('input:radio[name=import]').on('change', function(e) {
    if (e.target.value == "Windows") {
        insertHtml("#import-install", "windows-import.html");
    } else if (e.target.value == "macOS") {
        insertHtml("#import-install", "macOS-import.html");
    }
});

