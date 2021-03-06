#=
Pkg.clone("https://github.com/JuliaDB/DBI.jl.git")
Pkg.clone("https://github.com/iamed2/PostgreSQL.jl")
Pkg.clone("https://github.com/JuliaStats/MultivariateStats.jl.git")
Pkg.clone("https://github.com/JuliaStats/Clustering.jl")
=#
using DBI
using PostgreSQL
using Recsys
using Clustering
using MultivariateStats
#reload("Recsys")



SQL="select movie_id, user_id, rating from ratings;"
numGenero = 18
#numCluster = 10
kfold = 10
arrayGenero = [1:2]

method = "kfold"

inferior_limit = 2
superior_limit = 18

dataSet, originalDataSet = dataRetrieveAndNormalization(SQL)

for numCluster=inferior_limit:superior_limit
  dataClustering(dataSet, originalDataSet, method, numCluster)
  maeRmseEvaluateClusters(kfold, numCluster, method)
end

SQLGenerateByGenreNumber(arrayGenero, true)
maeRmseEvaluateGenres(arrayGenero, true)



function SQLGenerateByGenreNumber(arrayGenero, isGrupo)
  SQL="SELECT	r.user_id, r.movie_id, r.rating
            FROM ratings as r "
  sqli=""
  genres=""
  if isGrupo
    for i in arrayGenero
      sqlit=" join genres_movies as gm$i on gm$i.movie_id = r.movie_id
      join genres as g$i on g$i.id = gm$i.genre_id
      AND g$i.id = $i"
      sqli=string(sqli, sqlit)
      genres=string(genres, "-$i")
    end

    SQL = string(SQL, sqli, "ORDER BY r.user_id;")
    filename=string("genres", genres)
    clusteringCreate(SQL, filename)
  #Todos os filmes
  else
    for i in arrayGenero
      SQL="SELECT	r.user_id, r.movie_id, r.rating
            FROM ratings as r
            join genres_movies as gm on gm.movie_id = r.movie_id
      join genres as g on g.id = gm.genre_id AND g.id = $i
      ORDER BY r.user_id;"

      filename="gender-$i"
      clusteringCreate(SQL, filename)
    end
  end
end

# Cria cluster com os gêneros originais e salva em arquivo
function clusteringCreate(SQL, filename)
  conn = connect(Postgres, "localhost", "raul", "", "movielens", 5432)
  stmt = prepare(conn, SQL)
  result = execute(stmt)

  tuple = int(zeros(4)')
  for row in result
    tuple = vcat(tuple, [int(row[1]), int(row[2]), int(row[3]), 0]')
  end
  finish(stmt)
  disconnect(conn)
  writedlm("$path/original/$filename", tuple[2:length(tuple[:,1]),:])
end

# Recuperando matriz original e normalizando
function dataRetrieveAndNormalization(SQL)
  conn = connect(Postgres, "localhost", "postgres", "postgres", "movielens", 5432)
  dataSet= zeros(1682, 943)
  stmt = prepare(conn, SQL)
  result = execute(stmt)

  for row in result
    dataSet[row[1]; row[2]] = row[3]
  end
  originalDataSet = copy(dataSet)
  medias=zeros(1682)
  for i=1:length(dataSet[:,1])
    cont=0
    soma=0
    for j=1:length(dataSet[1,:])
      if dataSet[i;j] != 0
        soma += dataSet[i;j]
        cont+=1
      end
    end
    medias[i]=soma/cont;
  end
  for i=1:length(dataSet[:,1])
    for j=1:length(dataSet[1,:])
      dataSet[i;j]=dataSet[i;j]-medias[i]
    end
  end
  finish(stmt)
  disconnect(conn)
  return dataSet, originalDataSet
end

#Cria clusters e salva em arquivos
function dataClustering(dataSet, originalDataSet, method, numCluster)
  M=fit(PCA, dataSet'; maxoutdim=10)
  newMatrix=transform(M, dataSet')

  R = kmeans(newMatrix, numCluster; maxiter=200)
  c = counts(R)
  a = assignments(R)

  matrizClusters = [originalDataSet', a']'

  path=dirname(Base.source_path())
  matriz = matrizClusters

  for k=1:numCluster
    aux=int(zeros(4)')
    filename="cluster-$k"
    for i=1:length(matriz[:,1])
      if matriz[i,length(matriz[1,:])]==k
        for j=1:length(matriz[1,1:943])
          if matriz[i,j] != 0
            temp = int(zeros(4)')

            temp[1] = int(j)
            temp[2] = int(i)
            temp[3] = int(matriz[i,j])
            temp[4] = 0

            aux = vcat(aux, temp)
          end
        end
      end
    end
    if !isdir("$path/results-$method-$numCluster/")
      mkdir("$path/results-$method-$numCluster/")
    end
    writedlm("$path/results-$method-$numCluster/$filename", aux[2:length(aux[:,1]),:])
  end
end

# calcula o RMSE e o MAE e roda o IRSVD para cada um dos clusteres criados e salva em arquivos
function maeRmseEvaluateClusters(kfold, numCluster, method)
  resultsPredictionsTotal = zeros(1)
  testDataTotal = zeros(1)

  path=dirname(Base.source_path())

  for k=1:numCluster
    #resultsMAE = zeros(kfold)
    #resultsRMSE = zeros(kfold)
    resultsPredictions=zeros(kfold)

    filename="cluster-$k"
    results = "-results"

    if method == "kfold"
      resultsPredictions, testData = executeRecommenderKFold("$path/results-$method-$numCluster/$filename", kfold)
    elseif method == "holdout"
      resultsPredictions, testData = executeRecommenderHoldOut("$path/results-$method-$numCluster/$filename", kfold)
    else
      throw(Exception())
    end

    writedlm("$path/results-$method-$numCluster/$filename$results", [Recsys.mae(resultsPredictions, testData), Recsys.rmse(resultsPredictions, testData)])

    resultsPredictionsTotal = vcat(resultsPredictionsTotal, resultsPredictions)
    testDataTotal = vcat(testDataTotal, testData)

  end

  MAE = Recsys.mae(resultsPredictionsTotal[2:length(resultsPredictionsTotal)], testDataTotal[2:length(testDataTotal)])
  RMSE = Recsys.rmse(resultsPredictionsTotal[2:length(resultsPredictionsTotal)], testDataTotal[2:length(testDataTotal)])

  writedlm("$path/results-$method-$numCluster/all_results", [MAE, RMSE])
end

#Executa o recomendador k-vezes (kfold) e retorna as previsões
function executeRecommenderKFold(file, kfold)
  resultsPredictions=zeros(1)
  testDataAll = zero(1)

  data = Recsys.Dataset(file);
  experiment = Recsys.KFold(kfold);

  trainMAEs = Float64[]
  arrModel = Recsys.ImprovedRegularedSVD[]

  for i=1:kfold
    train_data = experiment.getTrainData(i);
    model = Recsys.ImprovedRegularedSVD(train_data, 10);
    train_data = train_data.file
    train_data = [train_data[:,1] train_data[:,2] train_data[:,3] train_data[:,4]]
    predictions = model.predict(train_data[:,1:2]);

    MAE = Recsys.mae(predictions, train_data[:,3])

    push!(arrModel, model)
    push!(trainMAEs, MAE)
  end

  index = indmin(trainMAEs)
  model01 = arrModel[index]

  test_data = experiment.getTestData(index);

  predictionsSVD = model01.predict(test_data[:,1:2]);

  resultsPredictions = vcat(resultsPredictions, predictionsSVD[:,1])
  testDataAll = vcat(testDataAll, test_data[:,3])

  return resultsPredictions[2:length(resultsPredictions)], testDataAll[2:length(testDataAll)]
end

#Executa o recomendador k-vezes em holdout e retorna as previsões
function executeRecommenderHoldOut(file, times)
  resultsPredictions=zeros(1)
  testDataAll = zero(1)
  for i=1:times
    data = Recsys.Dataset(file);

    experiment = Recsys.HoldOut(0.9, data);
    train_data = experiment.getTrainData();
    test_data = experiment.getTestData();

    model01 = Recsys.ImprovedRegularedSVD(train_data, 10);
    predictionsSVD = model01.predict(test_data[:,1:2]);

    resultsPredictions = vcat(resultsPredictions, predictionsSVD[:,1])
    testDataAll = vcat(testDataAll, test_data[:,3])
  end
  return resultsPredictions[2:length(resultsPredictions)], testDataAll[2:length(testDataAll)]
end

# calcula o RMSE e o MAE e roda o IRSVD para os gêneros originais agrupados ou não e salva em arquivos
function maeRmseEvaluateGenres(arrayGenero, isGrupo)
  path=dirname(Base.source_path())
  resultsPredictionsTotal = zeros(1)
  testDataTotal = zeros(1)
  nomeGenero = ""
  results = "-results"
  file=string("/original/all_results-group-", isGrupo)

  if isGrupo
    resultsMAE = zeros(kfold)
    resultsRMSE = zeros(kfold)
    resultsPredictions=zeros(kfold)
    for k in arrayGenero
      nomeGenero=string(nomeGenero, "-$k")
    end
    filename="genres$nomeGenero"
    resultsPredictions, testData = executeRecommenderKFold("$path/original/$filename", kfold)

    resultsPredictionsTotal = vcat(resultsPredictionsTotal, resultsPredictions)
    testDataTotal = vcat(testDataTotal, testData)
  else
    for k=1:numGenero
      resultsMAE = zeros(kfold)
      resultsRMSE = zeros(kfold)
      resultsPredictions=zeros(kfold)

      filename="gender-$k"
      resultsPredictions, testData = executeRecommenderKFold("$path/original/$filename", kfold)
      writedlm("$path/original/$filename$results", [Recsys.mae(resultsPredictions, testData), Recsys.rmse(resultsPredictions, testData)])

      resultsPredictionsTotal = vcat(resultsPredictionsTotal, resultsPredictions)
      testDataTotal = vcat(testDataTotal, testData)
    end
  end
  MAE = Recsys.mae(resultsPredictionsTotal[2:length(resultsPredictionsTotal)], testDataTotal[2:length(testDataTotal)])
  RMSE = Recsys.rmse(resultsPredictionsTotal[2:length(resultsPredictionsTotal)], testDataTotal[2:length(testDataTotal)])
  writedlm("$path$file", [MAE, RMSE])
end
