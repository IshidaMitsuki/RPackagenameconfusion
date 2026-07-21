# CS DID と BJS imputation の説明用まとめ

作成日: 2026-07-03

CS DID と、追加で実行した BJS imputation の考え方・違い・結果・解釈上の注意点をまとめたものである。細かい全出力の網羅ではなく、「何を推定しているのか」「なぜ2つの手法を見るのか」「結果をどう読むべきか」を優先する。

## 1. 問い

```text
1. CRANパッケージと同名のGitHubリポジトリが出現した後、
   CRANパッケージのダウンロード数は変化するのか。

2. その変化は、イベント前にCRAN/GitHub間の導線があるパッケージと、
   導線がないパッケージで異なるのか。
```

ここでいうイベントは、CRANパッケージと同名の、CRANから確認できる導線を持たないGitHubリポジトリが初めて出現した時点である。アウトカムは、月次CRANダウンロード数の対数 `log_dl` である。

## 2. データと変数の整理

分析単位は、パッケージと月の組み合わせである。

| 用語 | 意味 |
|---|---|
| `package` | CRANパッケージ |
| `period` | 月単位の時点 |
| `log_dl` | 月次ダウンロード数の対数 |
| `G` | 同名GitHubリポジトリが初めて出現した時点　≒ CRANパッケージが公開されてからの経過月数 |
| treated | 分析期間中にイベントを経験するパッケージ |
| never-treated | 分析期間中にイベントを経験しないパッケージ |
| `official_before_yes` | イベント前にCRAN/GitHub間の導線が確認されるパッケージ |
| `official_before_no` | イベント前にCRAN/GitHub間の導線が確認されないパッケージ |



## 3. CS DID の考え方

CS DID は、Callaway and Sant'Anna の staggered DID である。今回のように、処置時点 `G` がパッケージごとに異なる場合に使いやすい。

基本的には、各処置時点ごとに「その時点で処置済みのパッケージ」と「まだ処置されていない、またはnever-treatedのパッケージ」を比較して、群・時点ごとのATTを推定する。

```text
ATT(g,t) = E[Y_t(g) - Y_t(0) | G = g]
```

次のような比較を多数作って集約している。

```text
処置群の変化 - 比較群の変化
```

今回のCS DIDでは、主に次を見ている。

| 推定量 | 意味 |
|---|---|
| Dynamic ATT | イベント時点をそろえ、イベント後 `e=0..60` の平均効果を見る |
| Group ATT | 処置コホート単位で集約した効果 |
| Calendar ATT | カレンダー時点単位で集約した効果 |
| Balanced dynamic | イベント後12, 24, 36, 48期まで観測できるパッケージに揃えて動学効果を見る |

## 4. BJS imputation の考え方

BJS imputation は、Borusyak, Jaravel and Spiess の imputation型DIDである。CS DIDのように比較群との差を直接作るのではなく、未処置観測だけを使って「処置がなかった場合のアウトカム」を予測する。

今回の主仕様では、未処置アウトカムを次のように置いている。

```text
log_dl_it = alpha_i + lambda_t + error_it
```

ここで、`alpha_i` はパッケージ固定効果、`lambda_t` は時点固定効果である。このモデルを、未処置観測だけで推定する。

```text
G == 0 または period < G
```

そのうえで、処置後の観測について、実際の `log_dl` と「処置がなかった場合の予測値」の差を計算する。

```text
tau_hat_it = log_dl_it - y0_hat_it
```

BJSは、

```text
実際のDL - 処置がなかった場合の予測DL
```

を処置効果として見る方法である。

## 5. CS DID と BJS imputation の違い

反実仮想の作り方

| 観点 | CS DID | BJS imputation |
|---|---|---|
| 反実仮想の作り方 | 比較群との差から作る | 未処置アウトカムモデルから予測する |
| 基本単位 | `ATT(g,t)` | imputed residual |
| 処置時点がずれるデータ | 対応しやすい | 対応可能 |
| 動学効果 | 標準的に出しやすい | event-time別にresidualを集約する |
| 共変量 | `xformla`で調整しやすい | 主仕様は固定効果中心。時間不変変数はFEと重なりやすい |
| 今回の役割 | 主分析 | 手法に依存しないか確認する頑健性チェック |

したがって、CSとBJSで同じ方向の結果が出るなら、「特定の比較群の作り方だけに依存した結果ではない」と言いやすくなる。

## 6. 推定仕様の整理

### CS DID

今回のCS DIDでは、主仕様として次を採用している。

| 項目 | 内容 |
|---|---|
| イベント | 導線を持たない同名GitHubリポジトリの初出現 |
| アウトカム | `log_dl` |
| G<12 | 主仕様では除外しない |
| baseline12 | 主仕様から外す |
| 共変量 | `official`、`log_dl_pre3`、`pretrend_slope` 等 |
| dynamic window | `e=0..60` |
| balanced dynamic | `e0=12,24,36,48` |
| 感度分析 | never-treated only、G>=13 pre12、official_before_yes/no、G<12/G>=12 等 |

### BJS imputation

BJSでは、未処置アウトカムモデルを同じ形に保ち、サンプルを分けて確認している。

| 項目 | 内容 |
|---|---|
| 未処置アウトカムモデル | `log_dl_it = alpha_i + lambda_t + error_it` |
| 推定に使う観測 | `G==0` または `period < G` |
| 主推定量 | `dynamic_att_event_equal_0_60` |
| subgroup | `official_before_yes`, `official_before_no` |
| 感度分析 | `gte13`, `preobs_ge12` |
| 推論 | package-cluster bootstrap 499回 |
| 注意 | `se_naive` は記述的診断用で、主な推論には使わない |

## 7. 主な結果

CS DIDでもBJS imputationでも、イベント後のATTは正である。

| 仕様 | CS Dynamic ATT | BJS Dynamic ATT | 読み方 |
|---|---:|---:|---|
| Overall | 0.3569 | 0.4123 | 両手法で正 |
| official_before_yes | 0.4268 | 0.4675 | 導線あり群で大きい |
| official_before_no | 0.3454 | 0.3944 | 導線なし群でも正 |
| G>=13 / pre12系 | 0.3257 | 0.4718 | 処置前観測を確保しても正 |
| preobs_ge12 | - | 0.4659 | BJSで処置前観測数を直接制限した仕様 |

注意すべき点は、CSとBJSで完全に同一の推定量を見ているわけではないことである。CSの値は比較群を使ったDID推定量であり、BJSの値は未処置アウトカムモデルから作ったimputed residualの集約である。そのため、数値の大小を厳密に比較するより、「方向とパターンが揃っているか」を見るのが重要である。

## 8. 図表で見る結果

### CS DID: 仕様別Dynamic ATT

<p align="center">
  <img src="report_official_before/official_before_dynamic_att_forest.png" alt="CS dynamic ATT forest" width="900">
</p>

CS DIDでは、主分析、official_before_yes/no、never-treated only、G>=13 pre12などの仕様でDynamic ATTが正である。特にofficial_before_yesは推定値が大きい。

### BJS imputation: イベントスタディの推移

<p align="center">
  <img src="bjs_imputation/report/bjs_dynamic_event_study.png" alt="BJS dynamic event-study path" width="900">
</p>

BJSでも、イベント後にimputed ATTが正の方向で推移している。official_before_yesはofficial_before_noより高い水準で推移している。ただし、イベント前にも正の残差が見られるため、処置前から差があった可能性を示している。

### BJS imputation: 仕様別Dynamic ATT

<p align="center">
  <img src="bjs_imputation/report/bjs_dynamic_att_forest.png" alt="BJS dynamic ATT forest" width="850">
</p>

BJSのbootstrap CIでも、主要仕様のDynamic ATTは0を上回る。G>=13やpreobs_ge12に限定しても正の結果が残る。

### Balanced dynamic / horizon

<p align="center">
  <img src="report_official_before/official_before_balanced_dynamic_paths.png" alt="CS balanced dynamic paths" width="900">
</p>

<p align="center">
  <img src="bjs_imputation/report/bjs_balanced_horizon_paths.png" alt="BJS balanced horizon paths" width="900">
</p>

CS、BJSともに、短期だけでなく中長期でも正の推定値が残る。BJSではh12からh48にかけてATTが大きくなる傾向がある。

## 9. pre-trend の確認と解釈上の注意

今回の分析で最も注意すべき点は、pre-trendである。

CS DIDでも、イベント前の差が確認されている。特にofficial_before_yesでは、イベント前からDLの伸びや水準が比較群と異なる可能性が強い。

<p align="center">
  <img src="report_official_before/official_before_pretrend_significant_share.png" alt="CS pretrend significant share" width="900">
</p>

BJSでも、pre-trend/no-anticipation diagnosticで主要サンプルが棄却されている。

<p align="center">
  <img src="bjs_imputation/report/bjs_pretrend_wald_pvalues.png" alt="BJS pretrend Wald p-values" width="850">
</p>

この点は、結果を否定するものではない。しかし、「同名リポジトリが出現したからDLが増えた」と強く因果主張する際には制約になる。

より慎重には、次のように解釈するのが妥当である。

```text
同名GitHubリポジトリの出現後、CRAN DLは高い水準を示す。
この関連はCS DIDとBJS imputationの両方で確認される。
ただし、処置前から対象パッケージに可視性・人気・導線の差がある可能性があるため、
純粋な因果効果としてではなく、名前重複とパッケージの事前特性を含む関連として読む。
```



## 10. 現時点の結論

現時点では、次の結論が最も安全である。

```text
CRANパッケージと同名のGitHubリポジトリが出現した後、
CRANダウンロード数は高い水準を示す。

この結果は、CS DIDとBJS imputationの両方で確認される。
また、イベント前にCRAN/GitHub間の導線があるパッケージでは推定値が大きい。

ただし、処置前の差も確認されるため、
名前重複の純粋な因果効果として断定するより、
パッケージの事前の可視性・人気・導線を含む関連として解釈する必要がある。
```

## 12. 次にやるとよいこと

1. CSとBJSの対応する仕様を横並びにした図を作る。
2. official_before_yes/no のpre-eventだけを拡大し、どの時点から差があるか確認する。
3. SDIDまたはcohort-specificな補助分析で、反実仮想の作り方をさらに変えて確認する。
4. 論文本文では、CSとBJSの一致を「頑健性」、pre-trendを「限界」として明確に分けて書く。

