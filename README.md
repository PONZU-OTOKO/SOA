# AD同期オブジェクトのSOA一括変換

このスクリプトは、指定したユーザーまたはグループの Source of Authority (SOA) を Active Directory から Microsoft Entra ID に切り替えます。オブジェクトをまとめて削除する処理ではなく、CSVに残した行だけを変換します。

## 実行方法

Windows PowerShell 5.1 または PowerShell 7 で、管理対象テナントに接続できるアカウントを使用して実行します。

```powershell
.\Convert-SyncedObjectToCloudManaged.ps1
```

1. Microsoft Graph Authenticationモジュールがない場合、現在のユーザーへのインストール確認が表示されます。
2. ユーザーまたはグループを選択します。Graphにサインインしていない場合、サインインとアクセス許可の同意が求められます。
3. AD同期中オブジェクトの一覧CSVがカレントディレクトリに出力されます。CSVから変換対象外の行を削除して保存します。
4. 編集したCSVのパスを入力します。CSVの `Id` と `ObjectType` は変更しないでください。
5. スクリプトが選択された各IDの同期状態と現在のSOAを再確認します。表示された対象を確認して `TRANSFER` と入力すると変換します。
6. 各オブジェクトの成功・失敗を `Entra-SOA-Results-<日時>.csv` に出力します。

`-WhatIf` を指定するとGraphへの変更を行わず、対象と結果を確認できます。

```powershell
.\Convert-SyncedObjectToCloudManaged.ps1 -WhatIf
```

## 必要な権限

Graph PowerShellへのサインイン時に、選択種別に応じて次の委任アクセス許可を要求します。

| 対象 | 一覧取得 | SOA変更 |
|---|---|---|
| ユーザー | `User.Read.All` | `User-OnPremisesSyncBehavior.ReadWrite.All` |
| グループ | `Group.Read.All` | `Group-OnPremisesSyncBehavior.ReadWrite.All` |

SOA変更アクセス許可には管理者の同意が必要です。また、変更を行うサインインユーザーには、Microsoft Learnに記載されたサポート対象のEntraロール（最小ロールはハイブリッドID管理者）が必要です。管理者の同意が事前に済んでいない場合は、スクリプト実行前にテナント管理者へ依頼してください。

## 注意事項

- グループのSOA変更APIはMicrosoft Graph **beta** を使用します。beta APIは変更される可能性があり、本番利用はサポートされていません。スクリプトは実行時にも警告を表示します。
- 変換後はAD DSからの変更がEntra IDオブジェクトに反映されなくなります。AD同期を停止したり、ADオブジェクトを削除したりする操作ではありません。
- 変換対象がオンプレミスのExchangeやAD FS、パスワード認証を必要とするアプリケーションなどに依存していないか、Microsoft Learnの前提条件を確認してください。
- まず少数のテストアカウントで実行し、変更後の管理動作と同期クライアントの状態を確認してください。

## 参考資料

- [Microsoft Entra ID でユーザーの信頼のソース (SOA) を構成する](https://learn.microsoft.com/ja-jp/entra/identity/hybrid/how-to-user-source-of-authority-configure)
- [Update onPremisesSyncBehavior (Microsoft Graph beta)](https://learn.microsoft.com/graph/api/onpremisessyncbehavior-update?view=graph-rest-beta)
- [Transfer user SOA to Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/hybrid/user-source-of-authority-overview)
