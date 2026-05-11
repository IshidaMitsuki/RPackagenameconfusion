# CS2021 DID v8 結果メモ

更新日: 2026-05-09

## 推定設定

アウトカムは `log(1 + monthly downloads)`。処置時点 `G` は、CRAN公開後に同名のGitHubリポジトリが初めて観測された月である。

主分析は Callaway and Sant'Anna 型の group-time ATT を用いる。設定は `control_group = notyettreated`, `base_period = varying`, 共変量は `official + log_dl_pre3 + pretrend_slope` である。`baseline12` と `age_at_event` は主仕様から外した。

動学効果は `e = 0..60` で集計し、balanced dynamic は `balance_e = 12, 24, 36, 48` を併記する。

## 主分析と感度分析の位置づけ

主分析は、本研究で中心的に解釈する基本仕様である。ここでは、まだ同名GitHubリポジトリが出現していないパッケージを比較対象に使う `notyettreated` を control group とし、処置前の短期DL水準 `log_dl_pre3` と処置前トレンド `pretrend_slope`、および公式導線の有無 `official` を共変量として調整する。この仕様は、サンプルをできるだけ広く使いながら、処置前の利用規模と伸び方の違いをある程度そろえて、同名GitHub出現後の平均的な変化を見るためのものである。

通常 subgroup 分析は、主分析を official yes/no に分けて見る分析である。これは「同名GitHubリポジトリがある」こと自体に加えて、CRANや公式情報からGitHubへ誘導されているかどうかで、DL増加の大きさが異なるかを確認するために行う。

感度分析は、主分析の結果が特定の仕様選択に依存していないかを確認するための補助分析である。具体的には、比較対象を never-treated のみに限定する、処置前12期を観測できる `G>=13` のパッケージだけで pre12 共変量を使う、`G<12` と `G>=12` を分ける、さらに official yes/no それぞれで同じ確認を行う。したがって、感度分析の役割は新しい主結論を作ることではなく、主分析で見えた正の関連と official yes/no の差が、control group の選び方や短い処置前期間を持つパッケージの扱いにどの程度左右されるかを確認することである。

結果の読み方としては、まず主分析で全体の方向と大きさを確認し、次に通常 subgroup で official yes/no の違いを見る。そのうえで、感度分析でも符号・大きさ・official yes/no の相対関係が大きく崩れないかを確認する。今回の結果では、感度分析でもATTは一貫して正であり、official yes は official no より大きい。ただし pre-trend、特に official yes の処置前トレンドが強いため、因果効果として断定するのではなく、頑健な正の関連として慎重に解釈する。

## 仕様・推定量の解説

### 基本用語

`ATT` は Average Treatment Effect on the Treated の略で、処置を受けたパッケージについて、処置後のDLが比較対象に比べてどれだけ高いかを表す。ここでの処置は、CRAN公開後に同名GitHubリポジトリが出現することである。

`G` は処置時点である。たとえば `G=13` は、分析上の月番号で13期目に同名GitHubリポジトリが初めて観測されたことを意味する。`G=0` は never-treated、つまり観測期間内に同名GitHubリポジトリが出現しない比較対象である。

`e` はイベント時点からの相対月で、`e = t - G` で定義される。`e=0` は同名GitHubリポジトリが出現した月、`e=12` はその12か月後を表す。

`official` は、公式情報やCRAN上の導線からGitHubへ誘導されているかを表す指標である。`official yes` は公式導線あり、`official no` は公式導線なしである。

### control group

`notyettreated` は、ある時点でまだ処置を受けていないパッケージを比較対象に使う仕様である。将来処置を受けるパッケージも、その処置前であれば比較対象として使われる。サンプルを広く使えるため、主分析ではこの設定を使う。

`nevertreated` は、観測期間中に一度も同名GitHubリポジトリが出現しないパッケージだけを比較対象に使う仕様である。将来処置されるパッケージを比較対象から外すため、比較対象の解釈は明確になるが、not-yet-treated を使う場合より比較対象が限定される。感度分析では、主分析の結果が not-yet-treated の使い方に依存していないかを確認するために使う。

### 共変量仕様

`official + log_dl_pre3 + pretrend_slope` は主仕様である。`log_dl_pre3` は処置前3期のDL水準、`pretrend_slope` は処置前のDLトレンドを表す。これにより、処置前から人気が高いパッケージや、処置前から伸びているパッケージとの差を調整する。

`official + log_dl_pre12` は pre12 感度分析で使う仕様である。処置前12期を観測できる `G>=13` のパッケージに限定し、より長い処置前DL水準を調整する。G<12 のパッケージは処置前12期を持たないため、この仕様では除外される。

official yes/no に分けた分析では、`official` は群内で定数になる。そのため、実際の推定では `official` は自動的に落とされ、official yes では `log_dl_pre3 + pretrend_slope` または `log_dl_pre12`、official no でも同様の共変量になる。

### 集計推定量

`dynamic` は、イベント時点からの相対月 `e` に沿って効果を集計する推定量である。本分析では `e=0..60` を対象にしており、同名GitHub出現後の平均的なDL変化をイベント時間で見る。表にある dynamic ATT は、このイベントスタディ型の集計結果である。

`group` は、処置時点 `G` ごとに効果を集計したうえで平均する推定量である。早く処置されたコホートと遅く処置されたコホートを区別し、コホート単位で平均的な処置効果を見る。

`calendar` は、暦時点 `t` ごとに効果を集計する推定量である。特定の時期に共通ショックがある場合、calendar 集計を見ることで、暦月ベースでの平均的な処置効果を確認できる。

`dynamic_balanced_e12`, `dynamic_balanced_e24`, `dynamic_balanced_e36`, `dynamic_balanced_e48` は、指定したイベント後期間まで観測できるパッケージだけに限定した dynamic 集計である。たとえば `dynamic_balanced_e48` は、処置後48か月まで観測されるパッケージだけで `e=0..48` の効果を集計する。長期の効果を見るときに、途中で観測が切れるパッケージの影響を避けるために使う。

### 各仕様の意味

`Main: not-yet` は本研究の主分析である。not-yet-treated を比較対象にし、`official + log_dl_pre3 + pretrend_slope` を共変量として用いる。最も広いサンプルで、基本的な結論を確認する仕様である。

`Official yes` は、公式導線があるパッケージだけに限定した subgroup 分析である。公式情報からGitHubへ誘導されている場合に、同名GitHub出現後のDL増加がどの程度大きいかを見る。

`Official no` は、公式導線がないパッケージだけに限定した subgroup 分析である。Official yes と比較することで、公式導線を伴う場合と伴わない場合の差を確認する。

`never-treated only` は、比較対象を never-treated のみに限定した感度分析である。主分析で使う not-yet-treated control によって結果が左右されていないかを確認する。

`G>=13 pre12` は、処置前12期を観測できるパッケージだけに限定し、`log_dl_pre12` を共変量として使う感度分析である。G<12 のように処置前期間が短いパッケージが結果を左右していないかを確認する。

`G<12 subgroup` は、処置時点が早く、処置前12期を観測できないパッケージだけを見る分析である。初期に処置されたパッケージの結果を確認するための補助分析であり、pre-trend を十分に確認しにくい点に注意が必要である。

`G>=12 subgroup` は、処置前期間が比較的長いパッケージだけを見る分析である。G<12 のパッケージを除いても正の結果が残るかを確認する。

`official yes + never` は、official yes 群に限定したうえで、比較対象を never-treated のみにした感度分析である。official yes の大きな効果が not-yet-treated control の選び方に依存していないかを確認する。

`official yes + G>=13 pre12` は、official yes 群に限定し、さらに G>=13 のパッケージだけで pre12 共変量を使う感度分析である。公式導線あり群の結果が、処置前期間の短いパッケージによって作られていないかを確認する。

`official no + never` は、official no 群に限定したうえで、比較対象を never-treated のみにした感度分析である。official no 群でも正の関連が残るかを確認する。

`official no + G>=13 pre12` は、official no 群に限定し、G>=13 のパッケージだけで pre12 共変量を使う感度分析である。公式導線なし群について、より長い処置前期間を持つパッケージに限定しても結果が残るかを確認する。

## 主分析・通常 subgroup

| 仕様 | 推定量 | ATT | SE |
|---|---:|---:|---:|
| Main: not-yet | dynamic | 0.4011 | 0.0189 |
| Main: not-yet | group | 0.3558 | 0.0172 |
| Main: not-yet | calendar | 0.3403 | 0.0180 |
| Main: not-yet | balanced e12 | 0.1063 | 0.0111 |
| Main: not-yet | balanced e24 | 0.1896 | 0.0136 |
| Main: not-yet | balanced e36 | 0.2665 | 0.0171 |
| Main: not-yet | balanced e48 | 0.3438 | 0.0181 |
| Official yes | dynamic | 0.4964 | 0.0402 |
| Official yes | group | 0.4425 | 0.0368 |
| Official yes | calendar | 0.4336 | 0.0359 |
| Official yes | balanced e12 | 0.1036 | 0.0187 |
| Official yes | balanced e24 | 0.2214 | 0.0253 |
| Official yes | balanced e36 | 0.3210 | 0.0328 |
| Official yes | balanced e48 | 0.4278 | 0.0363 |
| Official no | dynamic | 0.3699 | 0.0203 |
| Official no | group | 0.3274 | 0.0198 |
| Official no | calendar | 0.3139 | 0.0217 |
| Official no | balanced e12 | 0.1069 | 0.0134 |
| Official no | balanced e24 | 0.1783 | 0.0171 |
| Official no | balanced e36 | 0.2461 | 0.0187 |
| Official no | balanced e48 | 0.3139 | 0.0220 |

![Aggregate ATT](report/aggregate_att.png)

![主要 dynamic ATT の比較](report/key_dynamic_att_forest.png)

![Balanced dynamic ATT](report/balanced_dynamic.png)

主分析の dynamic ATT は 0.4011 で、同名GitHubリポジトリの出現後にCRANダウンロードが相対的に増加している。通常 subgroup では official yes が 0.4964、official no が 0.3699 であり、公式への導線があるパッケージの方が増加幅は大きい。

## 感度分析

今回の追加実行は `CS2021_SENSITIVITY_ONLY=1` により、主分析・通常 subgroup をスキップして感度分析のみを実行した。全仕様は完走した。

| 仕様 | control | 共変量 | dynamic ATT | SE |
|---|---|---|---:|---:|
| never-treated only | nevertreated | official + log_dl_pre3 + pretrend_slope | 0.3698 | 0.0189 |
| G>=13 pre12 | notyettreated | official + log_dl_pre12 | 0.3290 | 0.0199 |
| G<12 subgroup | notyettreated | official + log_dl_pre3 + pretrend_slope | 0.4154 | 0.0481 |
| G>=12 subgroup | notyettreated | official + log_dl_pre3 + pretrend_slope | 0.3513 | 0.0209 |
| official yes + never | nevertreated | log_dl_pre3 + pretrend_slope | 0.4959 | 0.0394 |
| official yes + G>=13 pre12 | notyettreated | log_dl_pre12 | 0.4698 | 0.0419 |
| official no + never | nevertreated | log_dl_pre3 + pretrend_slope | 0.3236 | 0.0197 |
| official no + G>=13 pre12 | notyettreated | log_dl_pre12 | 0.2854 | 0.0229 |

official yes/no で分けた仕様では `official` は群内で定数になるため、自動的に共変量から落としている。これは意図通りである。

## Balanced dynamic の感度分析

| 仕様 | e12 | e24 | e36 | e48 |
|---|---:|---:|---:|---:|
| never-treated only | 0.0734 | 0.1599 | 0.2365 | 0.3145 |
| G>=13 pre12 | 0.0760 | 0.1556 | 0.2183 | 0.2856 |
| G<12 subgroup | 0.0457 | 0.1383 | 0.2321 | 0.3336 |
| G>=12 subgroup | 0.0766 | 0.1601 | 0.2313 | 0.3026 |
| official yes + never | 0.1029 | 0.2222 | 0.3228 | 0.4261 |
| official yes + G>=13 pre12 | 0.0912 | 0.2090 | 0.3041 | 0.4079 |
| official no + never | 0.0583 | 0.1337 | 0.2005 | 0.2707 |
| official no + G>=13 pre12 | 0.0679 | 0.1361 | 0.1872 | 0.2443 |

![Balanced dynamic の推移](report/key_balanced_dynamic_paths.png)

balanced dynamic はどの仕様でも e12 から e48 にかけて大きくなる。効果はイベント直後の一時的なジャンプというより、中期から長期にかけて累積的に現れるパターンに近い。

## Pre-trend 診断

| 仕様 | pre cells | p<0.05 cells | Wald p |
|---|---:|---:|---:|
| Main: not-yet | 7021 | 886 | <0.0001 |
| Official yes | 6806 | 1960 | <0.0001 |
| Official no | 7021 | 1062 | <0.0001 |
| never-treated only | 7140 | 1052 | <0.0001 |
| G>=13 pre12 | 7074 | 652 | <0.0001 |
| G<12 subgroup | 55 | 3 | 0.3536 |
| G>=12 subgroup | 7085 | 897 | <0.0001 |
| official yes + never | 6923 | 1893 | <0.0001 |
| official yes + G>=13 pre12 | 6857 | 1929 | <0.0001 |
| official no + never | 7140 | 1194 | <0.0001 |
| official no + G>=13 pre12 | 7074 | 804 | <0.0001 |

![Pre-trend 有意セル割合](report/key_pretrend_significant_share.png)

pre-trend は依然として重要な注意点である。特に official yes 群では処置前から伸びる傾向が強く、同名GitHubの出現後の増加をすべて処置効果として読むのは危険である。

## 結果の詳しい解説

まず全体の主分析を見ると、dynamic ATT は 0.4011 である。アウトカムは `log(1 + monthly downloads)` なので、この値は、同名GitHubリポジトリが出現した後に、処置群のCRANダウンロードが比較群に対して相対的に高くなっていることを示す。group 集計でも 0.3558、calendar 集計でも 0.3403 と正であり、集計方法を変えても符号は変わらない。したがって、基本的な結果は「同名GitHubリポジトリの出現後、CRANダウンロードは増える方向に動いている」と整理できる。

次に dynamic balanced の結果を見ると、主分析では e12 が 0.1063、e24 が 0.1896、e36 が 0.2665、e48 が 0.3438 である。これは、イベント後12か月まで観測できるパッケージに限定した平均効果よりも、24か月、36か月、48か月まで観測できるパッケージに限定した平均効果の方が大きいことを意味する。つまり、同名GitHub出現の直後だけに一時的な増加があるというより、イベント後しばらく時間が経つにつれて差が広がっているように見える。

official yes/no の通常 subgroup では、official yes の dynamic ATT が 0.4964、official no が 0.3699 である。どちらも正だが、official yes の方が大きい。これは、単に同名GitHubリポジトリが存在するだけでなく、CRANやパッケージ情報からGitHubへ誘導されている場合の方が、CRANダウンロードの増加と強く結びついていることを示している。balanced dynamic でも同じ傾向があり、e48 では official yes が 0.4278、official no が 0.3139 である。

感度分析でも、全体として正の結果は維持されている。比較対象を never-treated のみに限定した場合、dynamic ATT は 0.3698 である。これは主分析の 0.4011 よりやや小さいが、依然として正であり、標準誤差も 0.0189 と小さい。したがって、主分析の正の結果は、not-yet-treated を比較対象にしたことだけで生じているわけではない。

G>=13 pre12 仕様では dynamic ATT が 0.3290 である。この仕様は、処置前12期を観測できるパッケージに限定し、`log_dl_pre12` を共変量として使うため、処置前情報をより長く取れるパッケージだけに絞った確認である。ATT は主分析より小さくなるが、それでも正である。これは、G<12 のように処置前期間が短いパッケージを含めたことだけが正の結果を作っているわけではないことを示している。

G<12 と G>=12 の subgroup では、G<12 の dynamic ATT が 0.4154、G>=12 が 0.3513 である。G<12 の方が点推定は大きいが、標準誤差は 0.0481 と大きい。G<12 は処置前期間が短く、pre-trend を十分に確認しにくいため、結果の解釈には注意が必要である。一方、G>=12 でも 0.3513 と正なので、長めの処置前期間を持つパッケージに限定しても正の関連は残っている。

official yes/no に分けた感度分析は、通常 subgroup の結果を補強している。official yes では、never-treated only の dynamic ATT が 0.4959、G>=13 pre12 が 0.4698 である。official no では、それぞれ 0.3236、0.2854 である。どちらの感度分析でも official yes の方が official no より大きい。したがって、official yes の方がDL増加と強く結びつくという結果は、比較対象を変えても、処置前12期を観測できるパッケージに限定しても維持されている。

一方で、pre-trend 診断はかなり重要である。主分析では 7021 個のpre-trendセルのうち 886 個が 5%水準で有意であり、Wald検定も強く棄却している。official yes では 6806 個中 1960 個が有意で、感度分析でも official yes + never は 6923 個中 1893 個、official yes + G>=13 pre12 は 6857 個中 1929 個が有意である。これは official yes 群が、処置前から比較群と異なる伸び方をしていた可能性を示す。

したがって、結果の要点は二つに分けて読むのがよい。第一に、主分析と感度分析を通じて、同名GitHubリポジトリの出現後にCRANダウンロードが増えるという正の関連はかなり頑健である。第二に、official yes の方が official no より大きいという差も頑健である。ただし、official yes では処置前トレンドも強いため、この差をそのまま「公式誘導の純粋な因果効果」とは読まず、公式導線を持つパッケージがもともと可視性や成長力を持っていた可能性も含めて解釈する必要がある。

## 考察

主分析では、同名GitHubリポジトリの出現後にCRANダウンロードが増えるという結果が得られた。dynamic ATT は 0.4011 で、group と calendar の集計でも正である。通常 subgroup では official yes の効果が official no より大きく、公式への導線を伴うリポジトリの方がCRAN利用の増加と強く結びついている。

感度分析でもこの結論の方向は変わらない。control group を never-treated に限定しても dynamic ATT は 0.3698、G>=13 に限定して pre12 共変量を使っても 0.3290 であり、いずれも正である。G<12 subgroup でも ATT は 0.4154 と大きいが、標準誤差は大きく、観測される処置前期間が短いため、主たる根拠としてよりも補助的な確認として扱うのがよい。

official yes/no の感度分析は特に重要である。official yes は never-treated only で 0.4959、G>=13 pre12 で 0.4698。一方、official no はそれぞれ 0.3236、0.2854 である。したがって、公式導線あり群の効果が大きいという通常 subgroup の結果は、control group や pre12 制約を変えても残る。

ただし、official yes 群では pre-trend が非常に強い。これは「公式誘導があるから処置後にDLが増える」という解釈だけではなく、「もともと成長している、あるいは可視性の高いパッケージほど公式導線を伴うGitHubリポジトリを持ちやすい」という選択の可能性を示す。したがって、論文・発表では因果効果というより、処置前のDL水準・短期pretrendを調整しても残る、同名GitHub出現後の頑健な正の関連として表現するのが安全である。

結論として、同名GitHubリポジトリの出現はCRANダウンロードの増加と頑健に関連している。さらに、その関連は official yes 群で一貫して大きい。ただし official yes 群は処置前から成長傾向が強いため、公式導線の効果を因果的に主張するには慎重さが必要である。
