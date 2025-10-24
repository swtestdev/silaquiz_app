' VBA Timer Trigger Examples with Remote Server Support
' =====================================================

' Configuration - Change this to your server's IP address
Const SERVER_IP As String = "localhost"  ' Change to your server IP (e.g., "192.168.1.100", "DESKTOP-638BFEB")
Const SERVER_PORT As String = "8000"

' Get the full API URL
Function GetApiUrl() As String
    GetApiUrl = "http://" & SERVER_IP & ":" & SERVER_PORT & "/api/timer/trigger"
End Function

' Main function to send timer trigger
Sub SendTimerTrigger(triggerData As String)
    Dim http As Object
    Dim url As String
    Dim jsonData As String
    Dim response As String
    
    On Error GoTo ErrorHandler
    
    ' Create HTTP request object
    Set http = CreateObject("WinHttp.WinHttpRequest.5.1")
    
    ' Get API URL
    url = GetApiUrl()
    
    ' JSON payload
    jsonData = "{""trigger_data"": """ & triggerData & """}"
    
    ' Configure request
    http.Open "POST", url, False
    http.SetRequestHeader "Content-Type", "application/json"
    
    ' Send request
    http.Send jsonData
    
    ' Check response status
    If http.Status = 200 Then
        response = http.ResponseText
        MsgBox "Success: " & response, vbInformation, "Timer Trigger"
    Else
        MsgBox "Error " & http.Status & ": " & http.ResponseText, vbCritical, "Timer Trigger Error"
    End If
    
    ' Clean up
    Set http = Nothing
    Exit Sub
    
ErrorHandler:
    MsgBox "Error: " & Err.Description, vbCritical, "Timer Trigger Error"
    Set http = Nothing
End Sub

' Timer control functions
Sub StartTimerSlide(slideNumber As Integer)
    Call SendTimerTrigger(">>>>>>>START_TIMER>>>>>>>Slide#" & slideNumber & "##")
End Sub

Sub StartTimerSlide58()
    Call SendTimerTrigger(">>>>>>>START_TIMER>>>>>>>Slide#58##")
End Sub

Sub StartTimerSlide1()
    Call SendTimerTrigger(">>>>>>>START_TIMER>>>>>>>Slide#1##")
End Sub

Sub StopTimer()
    Call SendTimerTrigger(">>>>>>>STOP_TIMER>>>>>>>")
End Sub

Sub PauseTimer()
    Call SendTimerTrigger(">>>>>>>PAUSE_TIMER>>>>>>>")
End Sub

Sub ResumeTimer()
    Call SendTimerTrigger(">>>>>>>RESUME_TIMER>>>>>>>")
End Sub

' PowerPoint integration
Sub OnSlideShowNext(ByVal Wn As SlideShowWindow)
    Dim slideNumber As Integer
    slideNumber = Wn.View.CurrentSlide.SlideIndex
    Call StartTimerSlide(slideNumber)
End Sub

Sub OnSlideShowBegin(ByVal Wn As SlideShowWindow)
    Call StartTimerSlide(1)
End Sub

Sub OnSlideShowEnd(ByVal Wn As SlideShowWindow)
    Call StopTimer()
End Sub

' Test functions
Sub TestConnection()
    Call SendTimerTrigger(">>>>>>>START_TIMER>>>>>>>Slide#1##")
End Sub

Sub TestAllCommands()
    Call StartTimerSlide1()
    Application.Wait (Now + TimeValue("0:00:02"))
    Call PauseTimer()
    Application.Wait (Now + TimeValue("0:00:02"))
    Call ResumeTimer()
    Application.Wait (Now + TimeValue("0:00:02"))
    Call StopTimer()
End Sub
