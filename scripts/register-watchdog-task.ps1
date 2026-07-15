<#
.SYNOPSIS
  Registra o watchdog do Hermes no Agendador de Tarefas do Windows, rodando
  a cada 5 minutos indefinidamente.

.NOTES
  Rode uma vez, manualmente, em um PowerShell normal (nao precisa ser admin,
  a tarefa e criada no escopo do usuario atual). Para remover depois:
    Unregister-ScheduledTask -TaskName "Hermes Watchdog" -Confirm:$false
#>

$vbsPath = "C:\wslc\projects\hermes\scripts\run-watchdog-hidden.vbs"

# Chama o watchdog via wscript.exe + VBScript (WScript.Shell.Run com janela=0),
# nao powershell.exe direto - ver comentario em run-watchdog-hidden.vbs.
$action = New-ScheduledTaskAction -Execute "wscript.exe" `
  -Argument "//B `"$vbsPath`""

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes 5) `
  -RepetitionDuration (New-TimeSpan -Days 3650)   # ~10 anos - [TimeSpan]::MaxValue estoura o schema do Agendador

$settings = New-ScheduledTaskSettingsSet `
  -MultipleInstances IgnoreNew `
  -StartWhenAvailable `
  -DontStopOnIdleEnd `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

try {
  Register-ScheduledTask -TaskName "Hermes Watchdog" `
    -Action $action -Trigger $trigger -Settings $settings `
    -Description "Verifica /healthz do Hermes (n8n) a cada 5 min e reinicia o container se necessario." `
    -Force -ErrorAction Stop | Out-Null

  Write-Host "Tarefa 'Hermes Watchdog' registrada. Rodando a cada 5 min a partir de agora." -ForegroundColor Green
  Write-Host "Para conferir: Get-ScheduledTask -TaskName 'Hermes Watchdog' | Get-ScheduledTaskInfo"
  Write-Host "Para remover:  Unregister-ScheduledTask -TaskName 'Hermes Watchdog' -Confirm:`$false"
} catch {
  Write-Host "FALHOU ao registrar a tarefa: $_" -ForegroundColor Red
  exit 1
}
