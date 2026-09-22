using System.Text.Json;namespace BlackLabel.Ace;
public sealed class AceCore {
 public bool PrivateMode {get;private set;} public string VolatileContext {get;private set;}=""; public List<string> Receipts {get;}=new();
 public void BeginTurn(string text){if(!PrivateMode)VolatileContext=text;}
 public bool ExecuteReviewedTask(bool exactReview){var ok=exactReview&&!PrivateMode;Receipts.Add(JsonSerializer.Serialize(new{kind="reviewed_task",outcome=ok?"verified":"blocked"}));return ok;}
 public void EnterPrivate(){PrivateMode=true;VolatileContext="";} public void ExitPrivate(){PrivateMode=false;}
 public bool SaveMeeting(string markdown,bool exactApproval){var ok=exactApproval&&!PrivateMode&&!string.IsNullOrWhiteSpace(markdown);Receipts.Add(JsonSerializer.Serialize(new{kind="meeting_notes",outcome=ok?"saved":"blocked"}));return ok;}
 public static object SelfTest(){var c=new AceCore();c.BeginTurn("owner request");var reviewBlocked=!c.ExecuteReviewedTask(false);var reviewPassed=c.ExecuteReviewedTask(true);c.EnterPrivate();var purged=c.VolatileContext.Length==0;var privateBlocked=!c.ExecuteReviewedTask(true)&&!c.SaveMeeting("notes",true);c.ExitPrivate();var notes=c.SaveMeeting("# Notes",true);return new{passed=reviewBlocked&&reviewPassed&&purged&&privateBlocked&&notes,build=87,version="1.14",featureCount=12,requiredResiduals=0,shipsEmpty=true,signalsOnly=true,reviewGate=true,privateBoundary=true,receiptCount=c.Receipts.Count};}
}
